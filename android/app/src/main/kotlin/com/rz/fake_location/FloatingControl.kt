package com.rz.fake_location

import android.annotation.SuppressLint
import android.app.AppOpsManager
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.location.LocationManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.Process
import android.os.SystemClock
import android.provider.Settings
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import android.widget.LinearLayout
import android.widget.TextView

/**
 * 悬浮控制条：在其它应用之上显示当前模拟状态，并能暂停/继续、回到真实位置。
 *
 * 只在用户主动开启时创建；没有悬浮窗权限时返回失败，由界面引导去授权。
 */
class FloatingControl(private val context: Context) {
    private var view: View? = null
    private var params: WindowManager.LayoutParams? = null
    private var wm: WindowManager? = null
    private var statusText: TextView? = null
    private var toggleText: TextView? = null
    private val handler = Handler(Looper.getMainLooper())

    private val refresh = object : Runnable {
        override fun run() {
            updateText()
            handler.postDelayed(this, 1000)
        }
    }

    fun canShow(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return true
        return Settings.canDrawOverlays(context)
    }

    @SuppressLint("ClickableViewAccessibility")
    fun show(): Boolean {
        if (view != null) return true
        if (!canShow()) return false
        val manager = context.getSystemService(Context.WINDOW_SERVICE) as WindowManager

        val card = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setPadding(dp(14), dp(10), dp(14), dp(10))
            background = GradientDrawable().apply {
                cornerRadius = dp(18).toFloat()
                setColor(Color.parseColor("#E6181A20"))
                setStroke(dp(1), Color.parseColor("#33FFFFFF"))
            }
        }
        val status = TextView(context).apply {
            text = "模拟中"
            setTextColor(Color.WHITE)
            textSize = 12f
        }
        val actions = LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            setPadding(0, dp(6), 0, 0)
        }
        val toggle = TextView(context).apply {
            text = "暂停"
            setTextColor(Color.parseColor("#8AB4F8"))
            textSize = 12f
            setPadding(dp(6), dp(2), dp(6), dp(2))
            setOnClickListener {
                val intent = Intent(context, MockLocationService::class.java).apply {
                    if (RouteEngine.paused) {
                        action = MockLocationService.ACTION_RESUME
                    } else {
                        action = MockLocationService.ACTION_PAUSE
                    }
                }
                context.startService(intent)
                updateText()
            }
        }
        val stop = TextView(context).apply {
            text = "回真实位置"
            setTextColor(Color.parseColor("#F28B82"))
            textSize = 12f
            setPadding(dp(10), dp(2), dp(6), dp(2))
            setOnClickListener {
                context.stopService(Intent(context, MockLocationService::class.java))
                hide()
            }
        }
        actions.addView(toggle)
        actions.addView(stop)
        card.addView(status)
        card.addView(actions)

        val layout = WindowManager.LayoutParams(
            WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.WRAP_CONTENT,
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
            } else {
                @Suppress("DEPRECATION")
                WindowManager.LayoutParams.TYPE_PHONE
            },
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
            android.graphics.PixelFormat.TRANSLUCENT,
        ).apply {
            gravity = Gravity.TOP or Gravity.START
            x = dp(16)
            y = dp(160)
        }

        // 拖动移动悬浮条，不拦截点击
        card.setOnTouchListener(object : View.OnTouchListener {
            private var downX = 0f
            private var downY = 0
            private var startX = 0
            private var startY = 0
            private var dragging = false

            override fun onTouch(v: View, event: MotionEvent): Boolean {
                when (event.action) {
                    MotionEvent.ACTION_DOWN -> {
                        downX = event.rawX
                        downY = event.rawY.toInt()
                        startX = layout.x
                        startY = layout.y
                        dragging = false
                        return true
                    }
                    MotionEvent.ACTION_MOVE -> {
                        val dx = (event.rawX - downX).toInt()
                        val dy = event.rawY.toInt() - downY
                        if (kotlin.math.abs(dx) > dp(6) || kotlin.math.abs(dy) > dp(6)) dragging = true
                        if (dragging) {
                            layout.x = startX + dx
                            layout.y = startY + dy
                            try {
                                manager.updateViewLayout(card, layout)
                            } catch (_: Exception) {
                            }
                        }
                        return true
                    }
                    MotionEvent.ACTION_UP -> return dragging
                }
                return false
            }
        })

        return try {
            manager.addView(card, layout)
            wm = manager
            params = layout
            view = card
            statusText = status
            toggleText = toggle
            updateText()
            handler.postDelayed(refresh, 1000)
            true
        } catch (_: Exception) {
            false
        }
    }

    fun hide() {
        handler.removeCallbacks(refresh)
        val v = view ?: return
        try {
            wm?.removeView(v)
        } catch (_: Exception) {
        }
        view = null
        statusText = null
        toggleText = null
    }

    val isShowing: Boolean get() = view != null

    private fun updateText() {
        val status = statusText ?: return
        status.text = when {
            !MockLocationService.serviceActive -> "模拟服务已停止"
            RouteEngine.active && RouteEngine.paused -> "路线已暂停\n${readbackSummary()}"
            RouteEngine.active -> String.format(
                "%.1f 米/秒 · %d%%\n%s",
                RouteEngine.speed,
                (RouteEngine.progress() * 100).toInt(),
                readbackSummary(),
            )
            else -> String.format("目标 %.5f, %.5f\n%s", MockLocationService.currentLat, MockLocationService.currentLng, readbackSummary())
        }
        toggleText?.text = if (RouteEngine.paused) "继续" else "暂停"
        toggleText?.visibility = if (RouteEngine.active) View.VISIBLE else View.GONE
    }

    /** 独立读回每个系统源，不能因服务仍活着或某个源成功就宣称全部生效。 */
    @SuppressLint("MissingPermission")
    private fun readbackSummary(): String {
        // 撤销授权和下一次推送之间仍可能有近期模拟缓存，不能继续显示已确认。
        try {
            val ops = context.getSystemService(Context.APP_OPS_SERVICE) as AppOpsManager
            val mode = if (Build.VERSION.SDK_INT >= 29) {
                ops.unsafeCheckOpNoThrow(AppOpsManager.OPSTR_MOCK_LOCATION, Process.myUid(), context.packageName)
            } else {
                @Suppress("DEPRECATION")
                ops.checkOpNoThrow(AppOpsManager.OPSTR_MOCK_LOCATION, Process.myUid(), context.packageName)
            }
            if (mode != AppOpsManager.MODE_ALLOWED) return "模拟位置授权已失效"
        } catch (_: Exception) {
            return "模拟位置授权待确认"
        }
        val elapsed = SystemClock.elapsedRealtime() - MockLocationService.lastPushElapsedRealtimeMs
        if (!MockLocationService.running || elapsed !in 0L..4999L) return "定位推送待恢复"
        val providers = MockLocationService.expectedProviders
        if (providers.isEmpty()) return "系统定位源待确认"
        val manager = context.getSystemService(Context.LOCATION_SERVICE) as LocationManager
        val confirmed = providers.count { provider ->
            try {
                val fix = manager.getLastKnownLocation(provider) ?: return@count false
                @Suppress("DEPRECATION")
                val mock = if (Build.VERSION.SDK_INT >= 31) fix.isMock else fix.isFromMockProvider
                LocationFixPolicy.matchesMockTarget(
                    fix.latitude, fix.longitude,
                    if (fix.hasAccuracy()) fix.accuracy else Float.NaN,
                    LocationFixPolicy.ageMillis(SystemClock.elapsedRealtimeNanos(), fix.elapsedRealtimeNanos),
                    mock, MockLocationService.currentLat, MockLocationService.currentLng,
                )
            } catch (_: Exception) {
                false
            }
        }
        return if (confirmed == providers.size && MockLocationService.providerErrors.isEmpty()) {
            "系统源已读回 $confirmed/${providers.size}"
        } else {
            "系统源待确认 $confirmed/${providers.size}"
        }
    }

    private fun dp(value: Int): Int =
        (value * context.resources.displayMetrics.density).toInt()
}
