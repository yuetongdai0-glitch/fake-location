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
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.SystemClock
import kotlin.random.Random

/**
 * 前台服务：注册测试定位源，并每秒推送一次模拟坐标（WGS-84）。
 * 必须持续推送，否则系统/应用会认为定位过期并回落到真实位置。
 */
class MockLocationService : Service() {
    companion object {
        @Volatile var running = false
        private const val CHANNEL_ID = "mock_location"
        private const val NOTIFY_ID = 1001
    }

    private lateinit var lm: LocationManager
    private val handler = Handler(Looper.getMainLooper())
    private var lat = 0.0
    private var lng = 0.0
    private val providers = mutableListOf<String>()

    private val tick = object : Runnable {
        override fun run() {
            pushLocation()
            handler.postDelayed(this, 1000)
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        lm = getSystemService(LOCATION_SERVICE) as LocationManager
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        lat = intent?.getDoubleExtra("lat", lat) ?: lat
        lng = intent?.getDoubleExtra("lng", lng) ?: lng
        startAsForeground()
        if (providers.isEmpty()) setupProviders()
        running = true
        handler.removeCallbacks(tick)
        handler.post(tick)
        return START_REDELIVER_INTENT
    }

    /** 注册 GPS / 网络 / 融合定位三个测试源，覆盖大多数应用读取位置的方式。 */
    private fun setupProviders() {
        val names = mutableListOf(LocationManager.GPS_PROVIDER, LocationManager.NETWORK_PROVIDER)
        if (Build.VERSION.SDK_INT >= 31) names.add(LocationManager.FUSED_PROVIDER)
        for (p in names) {
            try {
                // 先移除可能残留的旧测试源，避免 addTestProvider 抛异常
                try { lm.removeTestProvider(p) } catch (_: Exception) {}
                @Suppress("DEPRECATION")
                lm.addTestProvider(
                    p, false, false, false, false, true, true, true,
                    Criteria.POWER_LOW, Criteria.ACCURACY_FINE
                )
                lm.setTestProviderEnabled(p, true)
                providers.add(p)
            } catch (_: Exception) {
                // 某些 ROM 不允许覆盖特定 provider，忽略即可，其余 provider 仍生效
            }
        }
    }

    private fun pushLocation() {
        for (p in providers) {
            val loc = Location(p).apply {
                // 加入极小抖动（约 ±0.5 米），避免坐标完全静止被部分应用判定为异常
                latitude = lat + (Random.nextDouble() - 0.5) * 0.00001
                longitude = lng + (Random.nextDouble() - 0.5) * 0.00001
                altitude = 50.0
                accuracy = 5f
                speed = 0f
                bearing = 0f
                time = System.currentTimeMillis()
                elapsedRealtimeNanos = SystemClock.elapsedRealtimeNanos()
                if (Build.VERSION.SDK_INT >= 26) {
                    verticalAccuracyMeters = 5f
                    speedAccuracyMetersPerSecond = 0.1f
                    bearingAccuracyDegrees = 0.1f
                }
            }
            try { lm.setTestProviderLocation(p, loc) } catch (_: Exception) {}
        }
    }

    private fun startAsForeground() {
        val nm = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= 26) {
            nm.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "虚拟定位", NotificationManager.IMPORTANCE_LOW)
            )
        }
        val pi = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, CHANNEL_ID)
        else @Suppress("DEPRECATION") Notification.Builder(this)
        val n = builder
            .setContentTitle("虚拟定位运行中")
            .setContentText(String.format("%.6f, %.6f", lat, lng))
            .setSmallIcon(android.R.drawable.ic_menu_mylocation)
            .setContentIntent(pi)
            .setOngoing(true)
            .build()
        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(NOTIFY_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION)
        } else {
            startForeground(NOTIFY_ID, n)
        }
    }

    override fun onDestroy() {
        handler.removeCallbacks(tick)
        // 停止时移除测试源，手机立即恢复真实定位
        for (p in providers) {
            try { lm.setTestProviderEnabled(p, false) } catch (_: Exception) {}
            try { lm.removeTestProvider(p) } catch (_: Exception) {}
        }
        providers.clear()
        running = false
        super.onDestroy()
    }
}
