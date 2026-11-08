package com.rz.fake_location

import android.Manifest
import android.annotation.SuppressLint
import android.content.Intent
import android.content.Context
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.Handler
import android.os.Looper
import android.app.AppOpsManager
import android.os.Build
import android.os.Process
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
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
    private val floating by lazy { FloatingControl(applicationContext) }

    /** 把推送频率、精度、步幅等设置塞进启动意图。 */
    private fun applyPushSettings(intent: Intent, call: MethodCall) {
        call.argument<Int>("intervalMs")?.let { intent.putExtra("intervalMs", it) }
        call.argument<Double>("accuracy")?.let { intent.putExtra("accuracy", it) }
        call.argument<Double>("stepLength")?.let { intent.putExtra("stepLength", it) }
    }

    /** 悬浮窗权限与显示状态。 */
    private fun overlayStatus(): Map<String, Any> = mapOf(
        "granted" to floating.canShow(),
        "showing" to floating.isShowing,
    )

    /**
     * WiFi / 网络定位的干扰情况。
     *
     * 高德、微信这类应用会用自己的 SDK 做 WiFi 指纹定位，刷新时重新算一遍，
     * 结果盖掉系统里的模拟位置。关掉 WiFi（或关闭“WiFi 扫描”）后它们就只能读系统位置。
     */
    private fun wifiStatus(): Map<String, Any?> {
        var enabled = false
        var ssid: String? = null
        try {
            val wm = applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
            if (wm != null) {
                enabled = wm.isWifiEnabled
                @Suppress("DEPRECATION")
                val info = wm.connectionInfo
                val raw = info?.ssid
                if (raw != null && raw != "<unknown>" && raw != "0x") {
                    ssid = raw.trim('"')
                }
            }
        } catch (_: Exception) {
        }
        // 即使 WiFi 开关关着，「WiFi 扫描始终可用」仍会让应用拿到热点信息
        val scanAlways = try {
            Settings.Global.getInt(contentResolver, "wifi_scan_always_enabled", 0) == 1
        } catch (_: Exception) {
            false
        }
        return mapOf(
            "enabled" to enabled,
            "ssid" to ssid,
            "scanAlwaysAvailable" to scanAlways,
            "interfering" to (enabled || scanAlways),
        )
    }

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
                    "openLocationSettings" -> {
                        try {
                            startActivity(Intent(Settings.ACTION_LOCATION_SOURCE_SETTINGS))
                        } catch (e: Exception) {
                            startActivity(Intent(Settings.ACTION_SETTINGS))
                        }
                        result.success(null)
                    }
                    "openUrl" -> {
                        val url = call.argument<String>("url")
                        if (url == null || !url.startsWith("https://")) {
                            result.error("BAD_URL", "只允许打开 https 链接", null)
                            return@setMethodCallHandler
                        }
                        try {
                            startActivity(
                                Intent(Intent.ACTION_VIEW, Uri.parse(url))
                                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            )
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("NO_BROWSER", "没有可用的浏览器", null)
                        }
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
                        applyPushSettings(intent, call)
                        if (Build.VERSION.SDK_INT >= 26) startForegroundService(intent) else startService(intent)
                        result.success(true)
                    }
                    // 路线模拟：点序列 + 速度 + 播放方式
                    "startRoute" -> {
                        val points = call.argument<List<Double>>("points")
                        val speed = call.argument<Double>("speed") ?: 1.4
                        val mode = call.argument<String>("mode") ?: RouteEngine.MODE_LOOP
                        if (points == null || points.size < 4 || points.size % 2 != 0) {
                            result.error("BAD_ARGS", "路线至少需要两个点", null)
                            return@setMethodCallHandler
                        }
                        if (points.any { it.isNaN() }) {
                            result.error("BAD_ARGS", "路线坐标非法", null)
                            return@setMethodCallHandler
                        }
                        if (!isSelectedMockApp()) {
                            result.error("NOT_MOCK_APP", "请先在开发者选项中把本应用设为模拟位置信息应用", null)
                            return@setMethodCallHandler
                        }
                        val intent = Intent(this, MockLocationService::class.java)
                            .putExtra("points", points.toDoubleArray())
                            .putExtra("speed", speed)
                            .putExtra("mode", mode)
                        applyPushSettings(intent, call)
                        if (Build.VERSION.SDK_INT >= 26) startForegroundService(intent) else startService(intent)
                        result.success(true)
                    }
                    "pauseMock", "resumeMock", "stopRoute" -> {
                        val action = when (call.method) {
                            "pauseMock" -> MockLocationService.ACTION_PAUSE
                            "resumeMock" -> MockLocationService.ACTION_RESUME
                            else -> MockLocationService.ACTION_STOP_ROUTE
                        }
                        startService(Intent(this, MockLocationService::class.java).setAction(action))
                        result.success(true)
                    }
                    "setSpeed" -> {
                        val speed = call.argument<Double>("speed")
                        if (speed == null || speed <= 0) {
                            result.error("BAD_ARGS", "速度非法", null)
                            return@setMethodCallHandler
                        }
                        startService(
                            Intent(this, MockLocationService::class.java)
                                .setAction(MockLocationService.ACTION_SPEED)
                                .putExtra("speed", speed),
                        )
                        result.success(true)
                    }
                    "overlayStatus" -> result.success(overlayStatus())
                    "wifiStatus" -> result.success(wifiStatus())
                    "openWifiSettings" -> {
                        try {
                            startActivity(
                                Intent(Settings.ACTION_WIFI_SETTINGS)
                                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                            )
                        } catch (_: Exception) {
                        }
                        result.success(null)
                    }
                    "openOverlaySettings" -> {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                            try {
                                startActivity(
                                    Intent(
                                        Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                                        Uri.parse("package:$packageName"),
                                    ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                                )
                            } catch (_: Exception) {
                            }
                        }
                        result.success(null)
                    }
                    "showFloat" -> result.success(floating.show())
                    "hideFloat" -> {
                        floating.hide()
                        result.success(true)
                    }
                    "stop" -> {
                        floating.hide()
                        stopService(Intent(this, MockLocationService::class.java))
                        result.success(true)
                    }
                    "isRunning" -> result.success(MockLocationService.running)
                    "mockStatus" -> {
                        val now = System.currentTimeMillis()
                        result.success(
                            mapOf(
                                "running" to MockLocationService.running,
                                "pushCount" to MockLocationService.pushCount,
                                "lastPushAt" to MockLocationService.lastPushAt,
                                "lat" to MockLocationService.currentLat,
                                "lng" to MockLocationService.currentLng,
                                "providers" to MockLocationService.activeProviders.toList(),
                                "mockApp" to isSelectedMockApp(),
                                "elapsedMs" to if (MockLocationService.lastPushAt == 0L) -1L
                                else now - MockLocationService.lastPushAt,
                                "routeActive" to RouteEngine.active,
                                "routePaused" to RouteEngine.paused,
                                "routeProgress" to RouteEngine.progress(),
                                "routeTravelled" to RouteEngine.travelled,
                                "routeTotal" to RouteEngine.total,
                                "routeSpeed" to RouteEngine.speed,
                                "routeBearing" to RouteEngine.bearing.toDouble(),
                                "intervalMs" to MockLocationService.intervalMs,
                                "floatShowing" to floating.isShowing,
                                "overlayGranted" to floating.canShow(),
                            ),
                        )
                    }
                    "openApp" -> {
                        val pkg = call.argument<String>("package")
                        if (pkg == null) {
                            result.error("BAD_ARGS", "缺少包名", null)
                            return@setMethodCallHandler
                        }
                        val intent = packageManager.getLaunchIntentForPackage(pkg)
                        if (intent == null) {
                            result.error("NOT_INSTALLED", "未安装该应用", null)
                            return@setMethodCallHandler
                        }
                        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        startActivity(intent)
                        result.success(true)
                    }
                    "getLocation" -> getLocation(call.argument<Boolean>("fresh") ?: false, result)
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
     * 取当前位置：先用各 provider 的近期缓存快速返回，
     * 精度不够时主动请求一次更新，20 秒内取精度最好的结果。
     * 返回精度、来源 provider 与是否为模拟位置，供界面提示用户。
     */
    @SuppressLint("MissingPermission")
    private fun getLocation(fresh: Boolean, result: MethodChannel.Result) {
        if (!hasLocationPermission()) {
            result.error("NO_PERMISSION", "未授予定位权限", null)
            return
        }
        val lm = getSystemService(LOCATION_SERVICE) as LocationManager
        val enabled = lm.getProviders(true).toSet()

        val cached = enabled.mapNotNull { provider ->
            try {
                lm.getLastKnownLocation(provider)
            } catch (_: Exception) {
                null
            }
        }.filter { System.currentTimeMillis() - it.time < 60_000 }
        val bestCached = cached.minByOrNull { it.accuracy }

        // 缓存足够准（30 米内）时直接返回，避免每次定位都要等 GPS；
        // fresh 为真时跳过缓存（停止模拟后需要马上拿到真实位置）
        if (!fresh && bestCached != null && bestCached.accuracy <= 30f) {
            result.success(payload(bestCached))
            return
        }

        val handler = Handler(Looper.getMainLooper())
        var best: Location? = bestCached
        var finished = false
        lateinit var listener: LocationListener

        fun finish() {
            if (finished) return
            finished = true
            handler.removeCallbacksAndMessages(null)
            try {
                lm.removeUpdates(listener)
            } catch (_: Exception) {
            }
            val location = best
            if (location == null) result.success(null) else result.success(payload(location))
        }

        listener = LocationListener { loc ->
            if (best == null || loc.accuracy < best!!.accuracy) best = loc
            // 精度足够就提前结束，不必等满 20 秒
            if (loc.accuracy <= 20f) finish()
        }

        val providers = buildList {
            add(LocationManager.GPS_PROVIDER)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                add(LocationManager.FUSED_PROVIDER)
            }
            add(LocationManager.NETWORK_PROVIDER)
        }.filter { it in enabled }

        if (providers.isEmpty()) {
            finish()
            return
        }
        for (provider in providers) {
            try {
                lm.requestLocationUpdates(provider, 0L, 0f, listener, Looper.getMainLooper())
            } catch (_: Exception) {
                // 个别 ROM 对 provider 有限制，失败时继续用其它 provider 与缓存
            }
        }
        handler.postDelayed({ finish() }, 20_000)
    }

    /** 是否有任一档定位权限。 */
    private fun hasLocationPermission(): Boolean =
        checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED ||
            checkSelfPermission(Manifest.permission.ACCESS_COARSE_LOCATION) == PackageManager.PERMISSION_GRANTED

    /** 把 Location 转成 Flutter 侧可读的字段，附带精度与模拟标记。 */
    private fun payload(loc: Location): Map<String, Any> {
        val mock = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            loc.isMock
        } else {
            @Suppress("DEPRECATION")
            loc.isFromMockProvider
        }
        return mapOf(
            "lat" to loc.latitude,
            "lng" to loc.longitude,
            "accuracy" to loc.accuracy.toDouble(),
            "provider" to (loc.provider ?: ""),
            "mock" to mock,
            "age" to ((System.currentTimeMillis() - loc.time) / 1000).coerceAtLeast(0L),
        )
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
