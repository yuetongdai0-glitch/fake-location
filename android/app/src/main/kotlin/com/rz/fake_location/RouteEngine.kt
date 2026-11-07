package com.rz.fake_location

import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * 路线（轨迹）引擎：把一串途经点当成折线，按当前速度沿折线插值移动。
 *
 * 坐标统一使用 WGS-84，和写入系统的坐标系保持一致，避免再绕一层坐标转换。
 * 支持单次、循环、往返三种播放方式，可随时暂停/继续、变速。
 */
object RouteEngine {
    /** 播放方式。 */
    const val MODE_ONCE = "once"
    const val MODE_LOOP = "loop"
    const val MODE_PINGPONG = "pingpong"

    @Volatile var active = false
        private set

    @Volatile var paused = false
        private set

    @Volatile var mode = MODE_LOOP
        private set

    /** 当前速度，米/秒。 */
    @Volatile var speed = 1.4
        private set

    /** 已累计移动的距离（往返模式下持续累加，用于进度）。 */
    @Volatile var travelled = 0.0
        private set

    /** 路线总长度（米）。 */
    @Volatile var total = 0.0
        private set

    /** 当前坐标（WGS-84）。 */
    @Volatile var latitude = 0.0
        private set
    @Volatile var longitude = 0.0
        private set

    /** 当前朝向（度，正北为 0）。 */
    @Volatile var bearing = 0f
        private set

    private var points: List<Pair<Double, Double>> = emptyList()
    private var cumulative = DoubleArray(0)

    /**
     * 开始一条新路线。[pts] 为 WGS-84 坐标列表，至少两个点。
     */
    fun start(
        pts: List<Pair<Double, Double>>,
        speedMetersPerSecond: Double,
        playMode: String,
    ): Boolean {
        if (pts.size < 2) return false
        points = pts
        cumulative = DoubleArray(pts.size)
        var sum = 0.0
        for (i in 1 until pts.size) {
            sum += distance(pts[i - 1].first, pts[i - 1].second, pts[i].first, pts[i].second)
            cumulative[i] = sum
        }
        if (sum <= 0.0) return false
        total = sum
        travelled = 0.0
        speed = speedMetersPerSecond.coerceIn(0.1, 300.0)
        mode = playMode
        paused = false
        active = true
        latitude = pts[0].first
        longitude = pts[0].second
        bearing = bearingBetween(pts[0], pts[1])
        return true
    }

    /** 暂停：位置停在原地，但仍在持续推送，防止系统回落到真实定位。 */
    fun pause() {
        if (active) paused = true
    }

    fun resume() {
        if (active) paused = false
    }

    /** 运行中调速，立即生效。 */
    fun setSpeed(value: Double) {
        speed = value.coerceIn(0.1, 300.0)
    }

    fun stop() {
        active = false
        paused = false
        points = emptyList()
        cumulative = DoubleArray(0)
        travelled = 0.0
        total = 0.0
    }

    /**
     * 前进 [dtMs] 毫秒，写回当前坐标。
     * 返回 true 表示坐标有更新（需要重新推送），false 表示已结束或暂停。
     */
    fun tick(dtMs: Long): Boolean {
        if (!active) return false
        if (paused) {
            // 暂停时保持坐标不变，但仍算一次推送，避免位置过期
            return true
        }
        travelled += speed * dtMs / 1000.0
        val d = when (mode) {
            MODE_PINGPONG -> {
                val phase = travelled % (total * 2)
                if (phase <= total) phase else total * 2 - phase
            }
            MODE_LOOP -> travelled % total
            else -> {
                if (travelled >= total) {
                    travelled = total
                    active = false
                    val p = points.last()
                    latitude = p.first
                    longitude = p.second
                    return true
                }
                travelled
            }
        }
        val index = segmentIndex(d)
        val from = points[index]
        val to = points[index + 1]
        val segStart = cumulative[index]
        val segLength = (cumulative[index + 1] - segStart).coerceAtLeast(0.0001)
        val ratio = ((d - segStart) / segLength).coerceIn(0.0, 1.0)
        latitude = from.first + (to.first - from.first) * ratio
        longitude = from.second + (to.second - from.second) * ratio
        bearing = bearingBetween(from, to)
        return true
    }

    /** 进度 0~1，供界面画进度条。 */
    fun progress(): Double {
        if (total <= 0.0) return 0.0
        return when (mode) {
            MODE_PINGPONG -> (travelled % (total * 2)) / (total * 2)
            MODE_LOOP -> (travelled % total) / total
            else -> (travelled / total).coerceIn(0.0, 1.0)
        }
    }

    /** 已经过的时间（秒），用距离/速度估算，够界面显示。 */
    fun elapsedSeconds(): Double = if (speed <= 0) 0.0 else travelled / speed

    private fun segmentIndex(d: Double): Int {
        // 二分查找 d 落在哪一段
        var low = 0
        var high = cumulative.size - 1
        while (low < high - 1) {
            val mid = (low + high) / 2
            if (cumulative[mid] <= d) low = mid else high = mid
        }
        return low.coerceIn(0, points.size - 2)
    }

    private fun bearingBetween(
        from: Pair<Double, Double>,
        to: Pair<Double, Double>,
    ): Float {
        val lat1 = Math.toRadians(from.first)
        val lat2 = Math.toRadians(to.first)
        val dLng = Math.toRadians(to.second - from.second)
        val y = sin(dLng) * cos(lat2)
        val x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLng)
        val deg = Math.toDegrees(atan2(y, x))
        return ((deg + 360) % 360).toFloat()
    }

    /** 两点间距离（米），用等距圆柱投影近似，城市尺度误差可以忽略。 */
    fun distance(lat1: Double, lng1: Double, lat2: Double, lng2: Double): Double {
        val meanLat = Math.toRadians((lat1 + lat2) / 2)
        val dx = (lng2 - lng1) * 111320.0 * cos(meanLat)
        val dy = (lat2 - lat1) * 110540.0
        return sqrt(dx * dx + dy * dy)
    }

    /** 从当前位置朝某个方位移动 [meters] 米后的坐标，摇杆用。 */
    fun offset(lat: Double, lng: Double, bearingDeg: Double, meters: Double): Pair<Double, Double> {
        val rad = Math.toRadians(bearingDeg)
        val dLat = meters * cos(rad) / 110540.0
        val dLng = meters * sin(rad) / (111320.0 * cos(Math.toRadians(lat)).coerceAtLeast(0.01))
        return Pair(lat + dLat, lng + dLng)
    }

    /** 两点间的方位角（度，正北为 0）。 */
    fun bearingTo(lat1: Double, lng1: Double, lat2: Double, lng2: Double): Float {
        val latA = Math.toRadians(lat1)
        val latB = Math.toRadians(lat2)
        val dLng = Math.toRadians(lng2 - lng1)
        val y = sin(dLng) * cos(latB)
        val x = cos(latA) * sin(latB) - sin(latA) * cos(latB) * cos(dLng)
        val deg = Math.toDegrees(atan2(y, x))
        return ((deg + 360) % 360).toFloat()
    }
}
