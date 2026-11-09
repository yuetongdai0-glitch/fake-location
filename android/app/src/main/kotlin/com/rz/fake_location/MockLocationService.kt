package com.rz.fake_location

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.location.Criteria
import android.location.Location
import android.location.LocationManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import kotlin.math.max

/**
 * 前台服务：注册测试定位源，按设定的频率推送模拟坐标（WGS-84）。
 *
 * 两种工作方式：
 * 1. 定点模拟：稳定保持指定坐标；
 * 2. 路线模拟：交给 [RouteEngine] 沿折线按速度移动，每 tick 取一次新坐标。
 *
 * 必须持续推送，否则系统/应用会认为定位过期并回落到真实位置。
 * 同时对外暴露推送次数、覆盖的 provider、路线进度等状态，供应用内界面读取。
 */
class MockLocationService : Service() {
    companion object {
        const val ACTION_PAUSE = "com.rz.fake_location.PAUSE"
        const val ACTION_RESUME = "com.rz.fake_location.RESUME"
        const val ACTION_STOP_ROUTE = "com.rz.fake_location.STOP_ROUTE"
        const val ACTION_SPEED = "com.rz.fake_location.SPEED"

        /** 服务存活与推送健康分开：短暂源故障期间服务仍会自动恢复。 */
        @Volatile var serviceActive = false
        @Volatile var running = false

        /** 已成功推送次数，用于判断服务是否真的在工作。 */
        @Volatile var pushCount = 0L

        /** 最后一次成功推送的时间戳（毫秒）。 */
        @Volatile var lastPushAt = 0L

        /** 单调时钟下的推送时间，设备校时不能导致诊断误判为过期。 */
        @Volatile var lastPushElapsedRealtimeMs = 0L

        /** 当前模拟坐标（WGS-84）。 */
        @Volatile var currentLat = 0.0
        @Volatile var currentLng = 0.0

        /** 推送间隔，毫秒。微信等应用建议 100，普通场景 500 足够。 */
        @Volatile var intervalMs = 500L

        /** 模拟精度（米），写进 Location.accuracy。 */
        @Volatile var accuracyMeters = 5.0

        /** 当前被成功接管为测试源的 provider 名称。 */
        val activeProviders: MutableList<String> =
            java.util.Collections.synchronizedList(mutableListOf())

        /** 预期覆盖与每源失败、推送时间独立上报，避免把部分生效误报为全局生效。 */
        @Volatile var expectedProviders: List<String> = emptyList()
        @Volatile var providerErrors: Map<String, String> = emptyMap()
        @Volatile var providerLastPushAt: Map<String, Long> = emptyMap()

        private const val CHANNEL_ID = "mock_location"
        private const val NOTIFY_ID = 1001
    }

    private lateinit var lm: LocationManager
    private lateinit var providerPump: MockProviderPump
    private val handler = Handler(Looper.getMainLooper())
    private var lat = 0.0
    private var lng = 0.0
    private var hasPosition = false
    private var lastTickAt = 0L
    private var notificationText = ""
    private var notificationAt = 0L
    private var currentBearing = 0f
    private var batchTimeMs = 0L
    private var batchElapsedRealtimeNanos = 0L
    private val manualMotion = ManualMotionState()

    private val tick = object : Runnable {
        override fun run() {
            val now = SystemClock.elapsedRealtime()
            val dt = if (lastTickAt == 0L) intervalMs else (now - lastTickAt).coerceIn(1, 5000)
            lastTickAt = now
            if (RouteEngine.active) {
                RouteEngine.tick(dt)
                // tick 可能刚好完成单程，仍要投递本次到达的终点。
                lat = RouteEngine.latitude
                lng = RouteEngine.longitude
                currentLat = lat
                currentLng = lng
                currentBearing = RouteEngine.bearing
            }
            pushLocation()
            updateNotificationIfNeeded()
            handler.postDelayed(this, intervalMs)
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        serviceActive = true
        lm = getSystemService(LOCATION_SERVICE) as LocationManager
        expectedProviders = buildList {
            add(LocationManager.GPS_PROVIDER)
            add(LocationManager.NETWORK_PROVIDER)
            // fused 名称早于公开常量存在；旧 ROM 只要实际提供就一并覆盖。
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S || "fused" in lm.allProviders) {
                add("fused")
            }
        }
        providerErrors = emptyMap()
        providerLastPushAt = emptyMap()
        pushCount = 0L
        lastPushAt = 0L
        lastPushElapsedRealtimeMs = 0L
        providerPump = MockProviderPump(
            expectedProviders,
            ::addProvider,
            publish = { provider ->
                // 部分 ROM 切换定位客户端/网络后会关闭测试源；不必移除源或打断其它订阅者。
                lm.setTestProviderEnabled(provider, true)
                lm.setTestProviderLocation(provider, buildLocation(provider))
            },
            reportFailure = { provider, failure ->
                Log.w("MockLocationService", "定位源推送失败：$provider", failure)
            },
        )
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        intent?.let { handleIntent(it) }
        // 进程重建后单独重投递的暂停/调速指令不含坐标，不能伪装成仍在模拟。
        if (!hasPosition) {
            running = false
            stopSelf(startId)
            return START_NOT_STICKY
        }
        startAsForeground()
        // 改坐标时立刻推一次，避免用户等待
        pushLocation()
        handler.removeCallbacks(tick)
        lastTickAt = SystemClock.elapsedRealtime()
        handler.postDelayed(tick, intervalMs)
        return START_REDELIVER_INTENT
    }

    /** 处理来自界面的各种指令：改坐标、开始路线、暂停、继续、调速。 */
    private fun handleIntent(intent: Intent) {
        when (intent.action) {
            ACTION_PAUSE -> RouteEngine.pause()
            ACTION_RESUME -> RouteEngine.resume()
            ACTION_STOP_ROUTE -> {
                RouteEngine.stop()
                manualMotion.reset()
            }
            ACTION_SPEED -> {
                val value = intent.getDoubleExtra("speed", RouteEngine.speed)
                RouteEngine.setSpeed(value)
            }
        }
        intent.getIntExtra("intervalMs", -1).let {
            if (it > 0) intervalMs = it.coerceIn(50, 5000).toLong()
        }
        intent.getDoubleExtra("accuracy", 0.0).let {
            if (it > 0) accuracyMeters = it.coerceIn(1.0, 100.0)
        }
        intent.getDoubleExtra("stepLength", 0.0).let {
            if (it > 0) stepLengthMeters = it.coerceIn(0.3, 1.2)
        }
        // 路线：经纬度交替存放，避免序列化嵌套列表
        val flat = intent.getDoubleArrayExtra("points")
        if (flat != null && flat.size >= 4) {
            val pts = ArrayList<Pair<Double, Double>>(flat.size / 2)
            var i = 0
            while (i + 1 < flat.size) {
                pts.add(Pair(flat[i], flat[i + 1]))
                i += 2
            }
            val speed = intent.getDoubleExtra("speed", 1.4)
            val mode = intent.getStringExtra("mode") ?: RouteEngine.MODE_LOOP
            if (RouteEngine.start(pts, speed, mode)) {
                manualMotion.reset()
                lat = RouteEngine.latitude
                lng = RouteEngine.longitude
                currentLat = lat
                currentLng = lng
                hasPosition = true
                currentBearing = RouteEngine.bearing
                lastTickAt = SystemClock.elapsedRealtime()
            }
        } else if (intent.hasExtra("lat") && intent.hasExtra("lng")) {
            RouteEngine.stop()
            lat = intent.getDoubleExtra("lat", lat)
            lng = intent.getDoubleExtra("lng", lng)
            currentLat = lat
            currentLng = lng
            hasPosition = true
            val speed = intent.getDoubleExtra("manualSpeed", 0.0)
            val bearing = intent.getDoubleExtra("manualBearing", 0.0)
            if (!manualMotion.update(speed, bearing, SystemClock.elapsedRealtime())) {
                manualMotion.reset()
            }
            currentBearing = manualMotion.bearing
        }
    }

    /** 接管单个定位源；addTestProvider 会覆盖同名源，无需先移除造成短暂真实位置泄漏。 */
    private fun addProvider(provider: String) {
        @Suppress("DEPRECATION")
        lm.addTestProvider(
            provider, provider == LocationManager.NETWORK_PROVIDER,
            provider == LocationManager.GPS_PROVIDER, false, false, true, true, true,
            if (provider == LocationManager.GPS_PROVIDER) Criteria.POWER_HIGH else Criteria.POWER_LOW,
            Criteria.ACCURACY_FINE,
        )
    }

    /** 每轮遍历全部预期源，包括启动时未接管成功以及后来被系统回收的源。 */
    private fun pushLocation() {
        if (!hasPosition) {
            running = false
            return
        }
        // 一轮使用同一坐标、精度和采样时刻，防止应用切换定位源时产生假位移。
        batchTimeMs = System.currentTimeMillis()
        batchElapsedRealtimeNanos = SystemClock.elapsedRealtimeNanos()
        val successful = providerPump.push(SystemClock.elapsedRealtime(), batchTimeMs)
        synchronized(activeProviders) {
            activeProviders.clear()
            activeProviders.addAll(successful)
        }
        providerErrors = providerPump.errors.toMap()
        providerLastPushAt = providerPump.lastPushAt.toMap()
        if (successful.isNotEmpty()) {
            pushCount++
            lastPushAt = batchTimeMs
            lastPushElapsedRealtimeMs = SystemClock.elapsedRealtime()
            running = true
        } else {
            // 服务仍会继续重试；是否全源生效由逐源读回结果判断。
            running = false
        }
    }

    private fun buildLocation(provider: String): Location {
        val speed = if (RouteEngine.active) {
            if (RouteEngine.paused) 0f else RouteEngine.speed.toFloat()
        } else manualMotion.speedAt(batchElapsedRealtimeNanos / 1_000_000L).toFloat()
        val moving = speed > 0f
        val accuracy = max(1f, accuracyMeters.toFloat())
        // 路线结束后保留已走步数；普通定点指令会清除路线计数。
        val steps = (RouteEngine.travelled / stepLength()).toInt()
        return Location(provider).apply {
            latitude = lat
            longitude = lng
            altitude = 50.0
            this.accuracy = accuracy
            this.speed = speed
            this.bearing = currentBearing
            time = batchTimeMs
            elapsedRealtimeNanos = batchElapsedRealtimeNanos
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                verticalAccuracyMeters = accuracy
                speedAccuracyMetersPerSecond = if (moving) 0.2f else 0.1f
                bearingAccuracyDegrees = if (moving) 3f else 0.1f
            }
            // 部分地图/运动 SDK 会读取卫星数、步数等附加信息。
            // 注意：不要在这里写 mock/模拟 之类的字段——mock 标记由系统在投递时打上，
            // 应用自己再写一遍只会让风控更容易识别。
            extras = Bundle().apply {
                putInt("satellites", 12)
                putInt("satelliteCount", 12)
                putDouble("meanCn0", 33.0)
                putDouble("maxCn0", 42.0)
                putBoolean("usedInFix", true)
                putInt("steps", steps)
                putInt("stepCount", steps)
            }
        }
    }

    /** 步幅，默认 0.65 米；路线页会通过 SPEED 指令一并给出速度。 */
    private var stepLengthMeters = 0.65

    private fun stepLength(): Double = stepLengthMeters.coerceIn(0.3, 1.2)

    /** 通知栏进度更新，2 秒一次，避免刷得太频繁。 */
    private fun updateNotificationIfNeeded() {
        val now = SystemClock.elapsedRealtime()
        if (now - notificationAt < 2000) return
        notificationAt = now
        val text = if (RouteEngine.active) {
            val percent = (RouteEngine.progress() * 100).toInt()
            String.format(
                "%s %.1f 米/秒 · %d%%",
                if (RouteEngine.paused) "已暂停" else "移动中",
                RouteEngine.speed,
                percent,
            )
        } else {
            String.format("%.6f, %.6f", lat, lng)
        }
        if (text == notificationText) return
        notificationText = text
        val nm = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        nm.notify(NOTIFY_ID, buildNotification(text))
    }

    private fun startAsForeground() {
        startForegroundCompat(buildNotification(String.format("%.6f, %.6f", lat, lng)))
    }

    private fun startForegroundCompat(notification: Notification) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIFY_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION)
        } else {
            startForeground(NOTIFY_ID, notification)
        }
    }

    private fun buildNotification(text: String): Notification {
        val nm = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            nm.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "虚拟定位", NotificationManager.IMPORTANCE_LOW),
            )
        }
        val pi = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setContentTitle(if (RouteEngine.active) "路线模拟中" else "虚拟定位运行中")
            .setContentText(text)
            .setSmallIcon(android.R.drawable.ic_menu_mylocation)
            .setContentIntent(pi)
            .setOngoing(true)
            .build()
    }

    override fun onDestroy() {
        handler.removeCallbacks(tick)
        RouteEngine.stop()
        // 停止时移除测试源，手机立即恢复真实定位
        // 曾注册但本轮失败的源也要清理，不能只清理当前成功列表。
        for (provider in expectedProviders) {
            try {
                lm.setTestProviderEnabled(provider, false)
            } catch (_: Exception) {
            }
            try {
                lm.removeTestProvider(provider)
            } catch (_: Exception) {
            }
        }
        activeProviders.clear()
        providerErrors = emptyMap()
        providerLastPushAt = emptyMap()
        expectedProviders = emptyList()
        serviceActive = false
        running = false
        super.onDestroy()
    }
}
