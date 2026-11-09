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
import android.app.ActivityManager
import android.os.Build
import android.os.PowerManager
import android.os.Process
import android.os.SystemClock
import android.provider.Settings
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Flutter 与原生之间的桥：启动/停止模拟定位服务、检查是否已被选为模拟位置应用、申请权限。
 */
class MainActivity : FlutterActivity() {
    private var appUpdater: AppUpdateController? = null
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

    /** 仅诊断后台限制，不请求自动电池豁免或读取其它应用的通知。 */
    private fun powerStatus(): Map<String, Any?> {
        val power = getSystemService(POWER_SERVICE) as? PowerManager
        val activity = getSystemService(ACTIVITY_SERVICE) as? ActivityManager
        return PowerDiagnostics.snapshot(
            Build.VERSION.SDK_INT,
            ignoringBatteryOptimizations = {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                    power?.isIgnoringBatteryOptimizations(packageName)
                } else null
            },
            powerSaveMode = { power?.isPowerSaveMode },
            backgroundRestricted = {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                    activity?.isBackgroundRestricted
                } else null
            },
            reportFailure = { name, failure ->
                Log.w("FakeLocation", "读取后台状态失败：$name", failure)
            },
        )
    }

    /**
     * WiFi / 网络定位的干扰情况。
     *
     * WiFi 开启只代表应用可能通过热点信息独立计算位置，不代表系统模拟必然失败。
     * 关闭 WiFi 后仍可能存在基站、IP 或应用缓存定位，需要结合逐源读回结果判断。
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
                try {
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
                                result.error("BAD_URL", "只允许打开安全网页链接", null)
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
                            val manualSpeed = call.argument<Double>("manualSpeed") ?: 0.0
                            val manualBearing = call.argument<Double>("manualBearing") ?: 0.0
                            if (!manualSpeed.isFinite() || manualSpeed !in 0.0..300.0 || !manualBearing.isFinite()) {
                                result.error("BAD_ARGS", "摇杆速度或方向无效", null)
                                return@setMethodCallHandler
                            }
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
                                .putExtra("manualSpeed", manualSpeed)
                                .putExtra("manualBearing", ((manualBearing % 360.0) + 360.0) % 360.0)
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
                            if (points.withIndex().any { (index, value) ->
                                    !value.isFinite() ||
                                        value !in if (index % 2 == 0) -90.0..90.0 else -180.0..180.0
                                } || points.chunked(2).distinct().size < 2 ||
                                !speed.isFinite() || speed < 0.1 || speed > 300 ||
                                mode !in setOf(RouteEngine.MODE_ONCE, RouteEngine.MODE_LOOP, RouteEngine.MODE_PINGPONG)
                            ) {
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
                            if (speed == null || !speed.isFinite() || speed < 0.1 || speed > 300) {
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
                        "powerStatus" -> result.success(powerStatus())
                        "openAppSettings" -> {
                            try {
                                startActivity(
                                    Intent(
                                        Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                                        Uri.parse("package:$packageName"),
                                    ),
                                )
                                result.success(null)
                            } catch (failure: Exception) {
                                Log.w("FakeLocation", "打开应用设置失败", failure)
                                result.error("SETTINGS_UNAVAILABLE", NativeErrorMessages.describe("打开应用设置失败", failure), null)
                            }
                        }
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
                        "isRunning" -> result.success(MockLocationService.serviceActive)
                        "mockStatus" -> {
                            val now = SystemClock.elapsedRealtime()
                            result.success(
                                mapOf(
                                    "deviceInfo" to deviceInfo(),
                                    "running" to MockLocationService.running,
                                    "serviceActive" to MockLocationService.serviceActive,
                                    "pushCount" to MockLocationService.pushCount,
                                    "lastPushAt" to MockLocationService.lastPushAt,
                                    "lat" to MockLocationService.currentLat,
                                    "lng" to MockLocationService.currentLng,
                                    "providers" to MockLocationService.activeProviders.toList(),
                                    "expectedProviders" to MockLocationService.expectedProviders,
                                    "providerErrors" to MockLocationService.providerErrors,
                                    "providerLastPushAt" to MockLocationService.providerLastPushAt,
                                    "providerLocations" to providerLocations(),
                                    "mockApp" to isSelectedMockApp(),
                                    "elapsedMs" to if (MockLocationService.lastPushElapsedRealtimeMs == 0L) -1L
                                    else now - MockLocationService.lastPushElapsedRealtimeMs,
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
                        "getLocation" -> getLocation(
                            call.argument<Boolean>("fresh") ?: false, result,
                            call.argument<Boolean>("cachedOnly") ?: false,
                            call.argument<Boolean>("realOnly") ?: false,
                        )
                        else -> result.notImplemented()
                    }
                } catch (failure: Exception) {
                    Log.w("FakeLocation", "执行定位操作失败", failure)
                    result.error("NATIVE_OPERATION_FAILED", NativeErrorMessages.describe("执行定位操作失败", failure), null)
                }
            }
        configureUpdateChannel(flutterEngine)
    }

    /**
     * 配置安卓应用内更新桥：查询本机版本，并在校验后下载、调起系统安装器。
     */
    private fun configureUpdateChannel(flutterEngine: FlutterEngine) {
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "fake_location/update")
        val updater = AppUpdateController(this) { channel.invokeMethod("updateStatus", it) }
        appUpdater = updater
        channel.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "version" -> {
                        val info = packageManager.getPackageInfo(packageName, 0)
                        result.success(mapOf(
                            "versionName" to info.versionName,
                            "versionCode" to versionCodeOf(info),
                            "sdkInt" to Build.VERSION.SDK_INT,
                        ))
                    }
                    "status" -> result.success(updater.status())
                    "download", "downloadAndInstall" -> {
                        val raw = call.arguments as? Map<*, *> ?: throw AppOperationException("更新信息无效")
                        result.success(updater.download(raw))
                    }
                    "cancelDownload" -> result.success(updater.cancel())
                    "install" -> result.success(updater.install())
                    else -> result.notImplemented()
                }
            } catch (failure: Exception) {
                Log.w("FakeLocation", "更新操作失败", failure)
                result.error("UPDATE_FAILED", if (failure is AppOperationException) failure.userMessage
                    else NativeErrorMessages.describe("更新失败", failure), null)
            }
        }
    }

    /** 返回安装来源授权页后续接同一安装动作，不重新下载。 */
    override fun onResume() {
        super.onResume()
        appUpdater?.onResume()
    }

    @Deprecated("Android 安装器仍通过 Activity 结果返回")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == AppUpdateController.INSTALL_REQUEST) appUpdater?.onInstallResult(resultCode)
    }

    /** 兼容新旧 Android 获取 versionCode，设备诊断也复用。 */
    private fun versionCodeOf(info: PackageInfo): Long = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
        info.longVersionCode
    } else {
        @Suppress("DEPRECATION")
        info.versionCode.toLong()
    }

    override fun onDestroy() {
        appUpdater?.close()
        super.onDestroy()
    }

    /**
     * 取当前位置：先用各 provider 的近期缓存快速返回，
     * 精度不够时主动请求一次更新，20 秒内取精度最好的结果。
     * 返回精度、来源 provider 与是否为模拟位置，供界面提示用户。
     */
    @SuppressLint("MissingPermission")
    private fun getLocation(fresh: Boolean, result: MethodChannel.Result, cachedOnly: Boolean = false, realOnly: Boolean = false) {
        if (!hasLocationPermission()) {
            result.error("NO_PERMISSION", "未授予定位权限", null)
            return
        }
        val lm = getSystemService(LOCATION_SERVICE) as LocationManager
        val enabled = lm.getProviders(true).toSet()
        val requireReal = realOnly || (fresh && !MockLocationService.serviceActive)
        fun usable(location: Location): Boolean = LocationFixPolicy.usable(
            location.latitude, location.longitude,
            if (location.hasAccuracy()) location.accuracy else Float.NaN,
            LocationFixPolicy.ageMillis(SystemClock.elapsedRealtimeNanos(), location.elapsedRealtimeNanos),
            isMockLocation(location), requireReal,
        )

        val cached = enabled.mapNotNull { provider ->
            try {
                lm.getLastKnownLocation(provider)
            } catch (_: Exception) {
                null
            }
        }.filter(::usable)
        val bestCached = cached.minByOrNull { it.accuracy }
        // 检测面板只读近期快照，不额外请求定位或等待二十秒后才展示后台限制。
        if (cachedOnly) {
            result.success(bestCached?.let(::payload))
            return
        }

        // 缓存足够准（30 米内）时直接返回，避免每次定位都要等 GPS；
        // fresh 为真时跳过缓存（停止模拟后需要马上拿到真实位置）
        if (!fresh && bestCached != null && bestCached.accuracy <= 30f) {
            result.success(payload(bestCached))
            return
        }

        val handler = Handler(Looper.getMainLooper())
        // fresh 用于停止模拟后的真实定位，旧 mock 缓存精度再高也不能压住新回调。
        var best: Location? = if (fresh) null else bestCached
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
            if (usable(loc)) {
                if (best == null || loc.accuracy < best!!.accuracy) best = loc
                // 足够精确的新回调优先于旧缓存，避免提前结束时反而返回旧位置。
                if (loc.accuracy <= 20f) {
                    best = loc
                    finish()
                }
            }
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
        var requests = 0
        for (provider in providers) {
            try {
                lm.requestLocationUpdates(provider, 0L, 0f, listener, Looper.getMainLooper())
                requests++
            } catch (_: Exception) {
                // 个别 ROM 对 provider 有限制，失败时继续用其它 provider 与缓存
            }
        }
        if (requests == 0) finish() else handler.postDelayed({ finish() }, 20_000)
    }

    /** 排查厂商与系统兼容性所需版本信息，不读取设备唯一标识或账号。 */
    private fun deviceInfo(): Map<String, Any?> {
        val version = packageManager.getPackageInfo(packageName, 0)
        return mapOf(
            "manufacturer" to Build.MANUFACTURER,
            "brand" to Build.BRAND,
            "model" to Build.MODEL,
            "androidVersion" to Build.VERSION.RELEASE,
            "sdkInt" to Build.VERSION.SDK_INT,
            "buildDisplay" to Build.DISPLAY,
            "buildIncremental" to Build.VERSION.INCREMENTAL,
            "appVersionName" to version.versionName,
            "appVersionCode" to versionCodeOf(version),
        )
    }

    /** 是否有任一档定位权限。 */
    private fun hasLocationPermission(): Boolean =
        checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED ||
            checkSelfPermission(Manifest.permission.ACCESS_COARSE_LOCATION) == PackageManager.PERMISSION_GRANTED

    /** 分别读回各系统定位源；一个源的成功不能证明其它应用使用的源也已生效。 */
    @SuppressLint("MissingPermission")
    private fun providerLocations(): List<Map<String, Any?>> {
        val lm = getSystemService(LOCATION_SERVICE) as LocationManager
        return MockLocationService.expectedProviders.map { provider ->
            try {
                if (!hasLocationPermission()) throw SecurityException("未授予定位权限")
                val location = lm.getLastKnownLocation(provider)
                if (location == null) {
                    mapOf("provider" to provider, "error" to "尚无定位缓存")
                } else {
                    payload(location) + mapOf(
                        "provider" to provider,
                        "ageMs" to LocationFixPolicy.ageMillis(
                            SystemClock.elapsedRealtimeNanos(), location.elapsedRealtimeNanos,
                        ),
                        "error" to null,
                    )
                }
            } catch (failure: Exception) {
                Log.w("FakeLocation", "读取定位源失败：$provider", failure)
                mapOf("provider" to provider, "error" to NativeErrorMessages.describe("读取定位源失败", failure))
            }
        }
    }

    /** 兼容不同系统版本读取模拟标记，不把过时回调误当成恢复的真实定位。 */
    private fun isMockLocation(loc: Location): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) loc.isMock else {
            @Suppress("DEPRECATION")
            loc.isFromMockProvider
        }

    /** 把 Location 转成 Flutter 可读字段，年龄统一用单调时钟。 */
    private fun payload(loc: Location): Map<String, Any> {
        return mapOf(
            "lat" to loc.latitude,
            "lng" to loc.longitude,
            "accuracy" to loc.accuracy.toDouble(),
            "provider" to (loc.provider ?: ""),
            "mock" to isMockLocation(loc),
            "age" to LocationFixPolicy.ageMillis(
                SystemClock.elapsedRealtimeNanos(), loc.elapsedRealtimeNanos,
            ).let { if (it < 0) -1L else it / 1000 },
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
