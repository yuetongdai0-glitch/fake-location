package com.rz.fake_location

import android.Manifest
import android.annotation.SuppressLint
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.app.AppOpsManager
import android.os.Build
import android.os.Process
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * Flutter 与原生之间的桥：启动/停止模拟定位服务、检查是否已被选为模拟位置应用、申请权限。
 */
class MainActivity : FlutterActivity() {
    companion object {
        private const val MAX_UPDATE_BYTES = 250L * 1024 * 1024
    }

    private val updateExecutor = Executors.newSingleThreadExecutor()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "fake_location/mock")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "requestPermissions" -> {
                        val perms = mutableListOf(
                            Manifest.permission.ACCESS_FINE_LOCATION,
                            Manifest.permission.ACCESS_COARSE_LOCATION
                        )
                        // Android 13+ 前台服务通知需要通知权限，否则通知不显示（服务仍可运行）
                        if (Build.VERSION.SDK_INT >= 33) perms.add(Manifest.permission.POST_NOTIFICATIONS)
                        val missing = perms.filter {
                            checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED
                        }
                        if (missing.isNotEmpty()) requestPermissions(missing.toTypedArray(), 1)
                        result.success(null)
                    }
                    "isMockApp" -> result.success(isSelectedMockApp())
                    "openDevSettings" -> {
                        try {
                            startActivity(Intent(Settings.ACTION_APPLICATION_DEVELOPMENT_SETTINGS))
                        } catch (e: Exception) {
                            startActivity(Intent(Settings.ACTION_SETTINGS))
                        }
                        result.success(null)
                    }
                    "start" -> {
                        val lat = call.argument<Double>("lat")
                        val lng = call.argument<Double>("lng")
                        // 边界校验：坐标必须在合法经纬度范围内
                        if (lat == null || lng == null || lat !in -90.0..90.0 || lng !in -180.0..180.0) {
                            result.error("BAD_ARGS", "坐标非法", null)
                            return@setMethodCallHandler
                        }
                        if (!isSelectedMockApp()) {
                            result.error("NOT_MOCK_APP", "请先在开发者选项中把本应用设为模拟位置信息应用", null)
                            return@setMethodCallHandler
                        }
                        val intent = Intent(this, MockLocationService::class.java)
                            .putExtra("lat", lat).putExtra("lng", lng)
                        if (Build.VERSION.SDK_INT >= 26) startForegroundService(intent) else startService(intent)
                        result.success(true)
                    }
                    "stop" -> {
                        stopService(Intent(this, MockLocationService::class.java))
                        result.success(true)
                    }
                    "isRunning" -> result.success(MockLocationService.running)
                    "getLocation" -> getLocation(result)
                    else -> result.notImplemented()
                }
            }
        configureUpdateChannel(flutterEngine)
    }

    /**
     * 配置安卓应用内更新桥：查询本机版本，并在校验后下载、调起系统安装器。
     */
    private fun configureUpdateChannel(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "fake_location/update")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "version" -> {
                        val info = packageManager.getPackageInfo(packageName, 0)
                        result.success(
                            mapOf(
                                "versionName" to info.versionName,
                                "versionCode" to versionCodeOf(info),
                            ),
                        )
                    }
                    "downloadAndInstall" -> {
                        val packageId = call.argument<String>("packageId")
                        val versionCode = call.argument<Int>("versionCode")
                        val apkUrl = call.argument<String>("apkUrl")
                        val sha256 = call.argument<String>("sha256")
                        val minimumSdk = call.argument<Int>("minSdk") ?: 1
                        if (packageId != packageName ||
                            versionCode == null || versionCode < 1 ||
                            apkUrl == null || !isTrustedUpdateUrl(apkUrl) ||
                            sha256 == null || !sha256.matches(Regex("^[0-9a-fA-F]{64}$")) ||
                            Build.VERSION.SDK_INT < minimumSdk
                        ) {
                            result.error("INVALID_UPDATE", "更新参数或当前系统版本不合法", null)
                            return@setMethodCallHandler
                        }
                        updateExecutor.execute {
                            try {
                                val apk = downloadAndVerify(packageId, versionCode, apkUrl, sha256)
                                runOnUiThread {
                                    try {
                                        startApkInstall(apk)
                                        result.success(true)
                                    } catch (failure: Exception) {
                                        result.error(
                                            if (failure is SecurityException) "INSTALL_PERMISSION" else "INSTALL_FAILED",
                                            failure.message ?: "无法启动系统安装器",
                                            null,
                                        )
                                    }
                                }
                            } catch (failure: Exception) {
                                runOnUiThread {
                                    result.error("UPDATE_FAILED", failure.message ?: "更新失败", null)
                                }
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * 下载更新包，并校验摘要、包名、版本号和签名后才能交给安装器。
     */
    private fun downloadAndVerify(
        expectedPackage: String,
        expectedVersionCode: Int,
        targetUrl: String,
        expectedSha256: String,
    ): File {
        val updateDir = File(cacheDir, "updates").apply { mkdirs() }
        val apk = File(updateDir, "fake-location-latest.apk")
        apk.delete()

        val connection = URL(targetUrl).openConnection() as HttpURLConnection
        connection.connectTimeout = 15_000
        connection.readTimeout = 30_000
        connection.instanceFollowRedirects = true
        connection.setRequestProperty("Accept", "application/octet-stream")
        connection.setRequestProperty("User-Agent", "fake-location-app/1.0")
        try {
            if (connection.responseCode !in 200..299) {
                throw IOException("下载失败：HTTP ${connection.responseCode}")
            }
            val declaredBytes = connection.contentLengthLong
            if (declaredBytes > MAX_UPDATE_BYTES) throw IOException("安装包超过体积上限")

            val digest = MessageDigest.getInstance("SHA-256")
            var received = 0L
            connection.inputStream.use { input ->
                FileOutputStream(apk).use { output ->
                    val buffer = ByteArray(32 * 1024)
                    while (true) {
                        val count = input.read(buffer)
                        if (count < 0) break
                        received += count
                        if (received > MAX_UPDATE_BYTES) throw IOException("安装包超过体积上限")
                        digest.update(buffer, 0, count)
                        output.write(buffer, 0, count)
                    }
                    output.fd.sync()
                }
            }
            if (received == 0L) throw IOException("下载内容为空")
            if (hex(digest.digest()) != expectedSha256.lowercase()) {
                throw IOException("安装包 SHA-256 校验失败")
            }
        } catch (failure: Exception) {
            apk.delete()
            throw failure
        } finally {
            connection.disconnect()
        }

        try {
            verifyApk(apk, expectedPackage, expectedVersionCode)
        } catch (failure: Exception) {
            apk.delete()
            throw failure
        }
        return apk
    }

    /**
     * 安装前检查新包身份和签名，阻止跨应用或错误签名包覆盖当前应用。
     */
    private fun verifyApk(apk: File, expectedPackage: String, expectedVersionCode: Int) {
        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            PackageManager.GET_SIGNING_CERTIFICATES
        } else {
            @Suppress("DEPRECATION")
            PackageManager.GET_SIGNATURES
        }
        val candidate = packageManager.getPackageArchiveInfo(apk.absolutePath, flags)
            ?: throw IOException("无法读取更新包信息")
        if (candidate.packageName != expectedPackage) throw IOException("更新包包名不一致")
        if (versionCodeOf(candidate) != expectedVersionCode.toLong()) {
            throw IOException("更新包版本号与清单不一致")
        }

        val installedFlags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            PackageManager.GET_SIGNING_CERTIFICATES
        } else {
            @Suppress("DEPRECATION")
            PackageManager.GET_SIGNATURES
        }
        val installed = packageManager.getPackageInfo(packageName, installedFlags)
        if (versionCodeOf(installed) >= versionCodeOf(candidate)) {
            throw IOException("更新包版本不高于当前已安装版本")
        }
        if (signatureHashes(installed) != signatureHashes(candidate)) {
            throw IOException("更新包签名与应用不一致，已阻止安装")
        }
    }

    /**
     * 启动系统 APK 安装器；Android 8 以上先确保用户已允许本应用安装未知来源应用。
     */
    private fun startApkInstall(apk: File) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && !packageManager.canRequestPackageInstalls()) {
            val settings = Intent(
                Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                Uri.parse("package:$packageName"),
            )
            settings.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(settings)
            throw SecurityException("请先允许“虚拟定位”安装未知来源应用，返回后再次点击更新")
        }
        val uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", apk)
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        startActivity(intent)
    }

    /**
     * 判断安装包下载地址是否来自受信任的 GitHub HTTPS 域名。
     */
    private fun isTrustedUpdateUrl(raw: String): Boolean {
        val uri = Uri.parse(raw)
        val host = uri.host?.lowercase() ?: return false
        return uri.scheme == "https" &&
            uri.userInfo == null &&
            uri.fragment == null &&
            (host == "raw.githubusercontent.com" ||
                host == "github.com" ||
                host.endsWith(".github.io"))
    }

    /**
     * 提取包内所有签名证书摘要，比较 v2/v3 与旧签名的兼容表示。
     */
    private fun signatureHashes(info: PackageInfo): Set<String> {
        val signatures = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            val signing = info.signingInfo ?: return emptySet()
            if (signing.hasMultipleSigners()) {
                signing.apkContentsSigners
            } else {
                signing.signingCertificateHistory
            }
        } else {
            @Suppress("DEPRECATION")
            info.signatures ?: return emptySet()
        }
        val digest = MessageDigest.getInstance("SHA-256")
        return signatures.mapTo(mutableSetOf()) { signature ->
            hex(digest.digest(signature.toByteArray()))
        }.also {
            if (it.isEmpty()) throw IOException("无法读取安装包签名")
        }
    }

    /**
     * 兼容新旧 Android 获取 versionCode。
     */
    private fun versionCodeOf(info: PackageInfo): Long {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            info.longVersionCode
        } else {
            @Suppress("DEPRECATION")
            info.versionCode.toLong()
        }
    }

    /**
     * 字节数组转小写十六进制。
     */
    private fun hex(bytes: ByteArray): String {
        val builder = StringBuilder(bytes.size * 2)
        for (byte in bytes) {
            val value = byte.toInt() and 0xff
            builder.append(value.toString(16).padStart(2, '0'))
        }
        return builder.toString()
    }

    override fun onDestroy() {
        updateExecutor.shutdownNow()
        try {
            updateExecutor.awaitTermination(2, TimeUnit.SECONDS)
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
        }
        super.onDestroy()
    }

    /**
     * 取当前位置：先用各 provider 中最新的缓存位置（2 分钟内），
     * 否则向 GPS/网络请求一次实时定位，10 秒超时返回 null。
     */
    @SuppressLint("MissingPermission")
    private fun getLocation(result: MethodChannel.Result) {
        if (checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) != PackageManager.PERMISSION_GRANTED &&
            checkSelfPermission(Manifest.permission.ACCESS_COARSE_LOCATION) != PackageManager.PERMISSION_GRANTED) {
            result.error("NO_PERMISSION", "未授予定位权限", null)
            return
        }
        val lm = getSystemService(LOCATION_SERVICE) as LocationManager
        val enabled = lm.getProviders(true)
        val last = enabled.mapNotNull { try { lm.getLastKnownLocation(it) } catch (_: Exception) { null } }
            .maxByOrNull { it.time }
        if (last != null && System.currentTimeMillis() - last.time < 120_000) {
            result.success(mapOf("lat" to last.latitude, "lng" to last.longitude))
            return
        }
        val handler = Handler(Looper.getMainLooper())
        var done = false
        lateinit var listener: LocationListener
        // 结束时统一注销监听，保证 result 只回调一次
        fun finish(loc: Location?) {
            if (done) return
            done = true
            lm.removeUpdates(listener)
            val l = loc ?: last
            result.success(l?.let { mapOf("lat" to it.latitude, "lng" to it.longitude) })
        }
        listener = LocationListener { finish(it) }
        val req = listOf(LocationManager.NETWORK_PROVIDER, LocationManager.GPS_PROVIDER).filter { it in enabled }
        if (req.isEmpty()) { finish(null); return }
        for (p in req) lm.requestLocationUpdates(p, 0L, 0f, listener, Looper.getMainLooper())
        handler.postDelayed({ finish(null) }, 10_000)
    }

    /** 通过 AppOps 判断当前应用是否被选为“模拟位置信息应用”。 */
    private fun isSelectedMockApp(): Boolean {
        return try {
            val ops = getSystemService(APP_OPS_SERVICE) as AppOpsManager
            val mode = if (Build.VERSION.SDK_INT >= 29) {
                ops.unsafeCheckOpNoThrow(AppOpsManager.OPSTR_MOCK_LOCATION, Process.myUid(), packageName)
            } else {
                @Suppress("DEPRECATION")
                ops.checkOpNoThrow(AppOpsManager.OPSTR_MOCK_LOCATION, Process.myUid(), packageName)
            }
            mode == AppOpsManager.MODE_ALLOWED
        } catch (e: Exception) {
            false
        }
    }
}
