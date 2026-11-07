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
import kotlin.math.max
import kotlin.random.Random

/**
 * 前台服务：注册测试定位源，按设定的频率推送模拟坐标（WGS-84）。
 *
 * 两种工作方式：
 * 1. 定点模拟：坐标固定，只做小幅抖动；
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

        @Volatile var running = false

        /** 已成功推送次数，用于判断服务是否真的在工作。 */
        @Volatile var pushCount = 0L

        /** 最后一次成功推送的时间戳（毫秒）。 */
        @Volatile var lastPushAt = 0L

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

        private const val CHANNEL_ID = "mock_location"
        private const val NOTIFY_ID = 1001
    }

    private lateinit var lm: LocationManager
    private val handler = Handler(Looper.getMainLooper())
    private var lat = 0.0
    private var lng = 0.0
    private var lastTickAt = 0L
    private var notificationText = ""
    private var notificationAt = 0L

    private val tick = object : Runnable {
        override fun run() {
            val now = SystemClock.elapsedRealtime()
            val dt = if (lastTickAt == 0L) intervalMs else (now - lastTickAt).coerceIn(1, 5000)
            lastTickAt = now
            if (RouteEngine.active) {
                RouteEngine.tick(dt)
                if (RouteEngine.active || RouteEngine.speed > 0) {
                    lat = RouteEngine.latitude
                    lng = RouteEngine.longitude
                    currentLat = lat
                    currentLng = lng
                }
            }
            pushLocation()
            updateNotificationIfNeeded()
            handler.postDelayed(this, intervalMs)
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        lm = getSystemService(LOCATION_SERVICE) as LocationManager
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        intent?.let { handleIntent(it) }
        startAsForeground()
        if (activeProviders.isEmpty()) setupProviders()
        running = true
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
            ACTION_STOP_ROUTE -> RouteEngine.stop()
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
                lat = RouteEngine.latitude
                lng = RouteEngine.longitude
                currentLat = lat
                currentLng = lng
                lastTickAt = SystemClock.elapsedRealtime()
            }
        } else if (intent.hasExtra("lat") && intent.hasExtra("lng")) {
            RouteEngine.stop()
            lat = intent.getDoubleExtra("lat", lat)
            lng = intent.getDoubleExtra("lng", lng)
            currentLat = lat
            currentLng = lng
        }
    }

    /** 注册 GPS / 网络 / 融合定位三个测试源，覆盖大多数应用读取位置的方式。 */
    private fun setupProviders() {
        val names = mutableListOf(
            LocationManager.GPS_PROVIDER,
            LocationManager.NETWORK_PROVIDER,
        )
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            names.add(LocationManager.FUSED_PROVIDER)
        }
        for (provider in names) {
            if (addProvider(provider)) activeProviders.add(provider)
        }
    }

    /** 尝试接管单个 provider，失败返回 false（部分 ROM 不允许覆盖）。 */
    private fun addProvider(provider: String): Boolean {
        return try {
            try {
                lm.removeTestProvider(provider)
            } catch (_: Exception) {
            }
            @Suppress("DEPRECATION")
            lm.addTestProvider(
                provider, false, false, false, false, true, true, true,
                Criteria.POWER_LOW, Criteria.ACCURACY_FINE,
            )
            lm.setTestProviderEnabled(provider, true)
            true
        } catch (_: Exception) {
            false
        }
    }

    private fun pushLocation() {
        if (lat == 0.0 && lng == 0.0) return
        var success = 0
        // 个别 ROM 会在其它应用请求定位时把测试源挤掉，失败时重新接管
        val snapshot = synchronized(activeProviders) { activeProviders.toList() }
        for (provider in snapshot) {
            val location = buildLocation(provider)
            try {
                lm.setTestProviderLocation(provider, location)
                success++
            } catch (_: Exception) {
                try {
                    if (addProvider(provider)) {
                        lm.setTestProviderLocation(provider, location)
                        success++
                    }
                } catch (_: Exception) {
                }
            }
        }
        if (success > 0) {
            pushCount++
            lastPushAt = System.currentTimeMillis()
            running = true
        } else {
            // 一个都没成功，说明已失去测试源权限
            running = false
        }
    }

    private fun buildLocation(provider: String): Location {
        // 静止时抖动约 ±0.3 米；移动时抖动更小，看起来更顺滑
        val moving = RouteEngine.active && !RouteEngine.paused
        val jitter = if (moving) 0.000002 else 0.000006
        val baseAccuracy = accuracyMeters.toFloat()
        val accuracy = max(1f, baseAccuracy + (Random.nextFloat() - 0.5f) * 1.5f)
        val speed = if (moving) RouteEngine.speed.toFloat() else 0f
        val bearing = if (RouteEngine.active) RouteEngine.bearing else 0f
        // 步频模拟：按步幅折算累计步数
        val steps = if (RouteEngine.active) (RouteEngine.travelled / stepLength()).toInt() else 0
        return Location(provider).apply {
            latitude = lat + (Random.nextDouble() - 0.5) * jitter
            longitude = lng + (Random.nextDouble() - 0.5) * jitter
            altitude = 50.0
            this.accuracy = accuracy
            this.speed = speed
            this.bearing = bearing
            time = System.currentTimeMillis()
            elapsedRealtimeNanos = SystemClock.elapsedRealtimeNanos()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                verticalAccuracyMeters = accuracy
                speedAccuracyMetersPerSecond = if (moving) 0.2f else 0.1f
                bearingAccuracyDegrees = if (moving) 3f else 0.1f
            }
            // 部分地图/运动 SDK 会读取卫星数、步数等附加信息。
            // 注意：不要在这里写 mock/模拟 之类的字段——mock 标记由系统在投递时打上，
            // 应用自己再写一遍只会让风控更容易识别。
            extras = Bundle().apply {
                putInt("satellites", 10 + Random.nextInt(5))
                putInt("satelliteCount", 10 + Random.nextInt(5))
                putDouble("meanCn0", 30.0 + Random.nextDouble() * 6)
                putDouble("maxCn0", 38.0 + Random.nextDouble() * 6)
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
        val now = System.currentTimeMillis()
        if (now - notificationAt < 2000) return
        notificationAt = now
        val text = if (RouteEngine.active) {
            val percent = (RouteEngine.progress() * 100).toInt()
            String.format(
                "%s %.1f m/s · %d%%",
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
        val snapshot = synchronized(activeProviders) { activeProviders.toList() }
        for (provider in snapshot) {
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
        running = false
        super.onDestroy()
    }
}
