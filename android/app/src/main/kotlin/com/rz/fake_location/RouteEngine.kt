package com.rz.fake_location

import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.sin

/**
 * 路线（轨迹）引擎：把一串途经点当成折线，按当前速度沿折线插值移动。
 *
 * 坐标统一使用 WGS-84，和写入系统的坐标系保持一致，避免再绕一层坐标转换。
 * 支持单次、循环、往返三种播放方式，可随时暂停/继续、变速。
 */
object RouteEngine {
    /** 与界面、路线工具一致的平均地球半径；球面模型不宣称椭球测绘精度。 */
    const val EARTH_RADIUS_METERS = 6371008.8
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
    private var elapsedMovingSeconds = 0.0

    /**
     * 开始一条新路线。[pts] 为 WGS-84 坐标列表，至少两个点。
     */
    fun start(
        pts: List<Pair<Double, Double>>,
        speedMetersPerSecond: Double,
        playMode: String,
    ): Boolean {
        if (pts.size < 2 || !speedMetersPerSecond.isFinite() || speedMetersPerSecond < 0.1 || speedMetersPerSecond > 300 ||
            playMode !in setOf(MODE_ONCE, MODE_LOOP, MODE_PINGPONG) ||
            pts.any { (lat, lng) -> lat !in -90.0..90.0 || lng !in -180.0..180.0 }
        ) return false
        // 先消除连续重合点，否则首段朝向和零长段插值没有确定意义。
        val cleaned = mutableListOf(pts.first())
        for (point in pts.drop(1)) {
            if (distanceBetween(cleaned.last(), point) > 0.000001) cleaned.add(point)
        }
        if (cleaned.size < 2) return false
        // 循环必须实际走完回程，不能在终点用取模瞬移回起点。
        if (playMode == MODE_LOOP && distanceBetween(cleaned.last(), cleaned.first()) > 0.000001) {
            cleaned.add(cleaned.first())
        }
        val distances = DoubleArray(cleaned.size)
        var sum = 0.0
        for (i in 1 until cleaned.size) {
            sum += distanceBetween(cleaned[i - 1], cleaned[i])
            distances[i] = sum
        }
        if (!sum.isFinite() || sum <= 0.0) return false
        // 完整校验后再替换运行态，错误路线不能破坏正在运行的旧路线。
        points = cleaned.toList()
        cumulative = distances
        total = sum
        travelled = 0.0
        elapsedMovingSeconds = 0.0
        speed = speedMetersPerSecond
        mode = playMode
        paused = false
        active = true
        latitude = points[0].first
        longitude = points[0].second
        bearing = bearingBetween(points[0], points[1])
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
        if (!value.isFinite() || value < 0.1 || value > 300) return
        speed = value
    }

    fun stop() {
        active = false
        paused = false
        points = emptyList()
        cumulative = DoubleArray(0)
        travelled = 0.0
        total = 0.0
        speed = 0.0
        elapsedMovingSeconds = 0.0
    }

    /**
     * 前进 [dtMs] 毫秒，写回当前坐标。
     * 返回 true 表示当前路线坐标仍可投递（暂停时保持原位）；无活动路线或非正时间返回 false。
     */
    fun tick(dtMs: Long): Boolean {
        if (!active || dtMs <= 0) return false
        if (paused) {
            // 暂停时保持坐标不变，但仍算一次推送，避免位置过期
            return true
        }
        val seconds = dtMs.toDouble() / 1000.0
        val movingSeconds = if (mode == MODE_ONCE) {
            seconds.coerceAtMost((total - travelled).coerceAtLeast(0.0) / speed)
        } else seconds
        elapsedMovingSeconds += movingSeconds
        travelled = if (mode == MODE_ONCE && seconds >= (total - travelled) / speed) {
            total
        } else travelled + speed * movingSeconds
        var returning = false
        val d = when (mode) {
            MODE_PINGPONG -> {
                val phase = travelled % (total * 2)
                returning = phase >= total
                if (returning) total * 2 - phase else phase
            }
            MODE_LOOP -> travelled % total
            else -> {
                if (travelled >= total) {
                    travelled = total
                    active = false
                    total
                } else {
                    travelled
                }
            }
        }
        var index = segmentIndex(d)
        // 返程恰好到达一个拐点时，应沿前一段继续返回。
        if (returning && index > 0 && d == cumulative[index]) index--
        val from = points[index]
        val to = points[index + 1]
        val segStart = cumulative[index]
        val segLength = cumulative[index + 1] - segStart
        val ratio = ((d - segStart) / segLength).coerceIn(0.0, 1.0)
        val current = when {
            ratio <= 0.0 -> from
            ratio >= 1.0 -> to
            else -> offset(from.first, from.second, initialBearingDegrees(from.first, from.second, to.first, to.second), segLength * ratio)
        }
        latitude = current.first
        longitude = current.second
        bearing = if (returning) {
            bearingBetween(current, from)
        } else if (ratio >= 1.0) {
            ((bearingBetween(to, from) + 180f) % 360f)
        } else {
            bearingBetween(current, to)
        }
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

    /** 实际累计移动时间；变速后不重算过去的时间，暂停不计入。 */
    fun elapsedSeconds(): Double = elapsedMovingSeconds

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
        return bearingTo(from.first, from.second, to.first, to.second)
    }

    private fun distanceBetween(from: Pair<Double, Double>, to: Pair<Double, Double>): Double =
        distance(from.first, from.second, to.first, to.second)

    /** 球面最短距离；向量夹角形式在日期变更线、极点和近对跖点均保持有限。 */
    fun distance(lat1: Double, lng1: Double, lat2: Double, lng2: Double): Double {
        require(validCoordinate(lat1, lng1) && validCoordinate(lat2, lng2)) { "坐标必须是有效的有限经纬度" }
        val latA = Math.toRadians(lat1)
        val latB = Math.toRadians(lat2)
        val dLng = Math.toRadians(normalizeLongitude(lng2 - lng1))
        val y = cos(latB) * sin(dLng)
        val x = cos(latA) * sin(latB) - sin(latA) * cos(latB) * cos(dLng)
        val dot = sin(latA) * sin(latB) + cos(latA) * cos(latB) * cos(dLng)
        return EARTH_RADIUS_METERS * atan2(Math.hypot(x, y), dot)
    }

    /** 从当前位置朝某个方位移动 [meters] 米后的坐标，摇杆用。 */
    fun offset(lat: Double, lng: Double, bearingDeg: Double, meters: Double): Pair<Double, Double> {
        require(validCoordinate(lat, lng) && bearingDeg.isFinite() && meters.isFinite()) { "位移参数必须为有效的有限数值" }
        if (meters == 0.0) return lat to lng
        val latitude = Math.toRadians(lat)
        val longitude = Math.toRadians(lng)
        val bearing = Math.toRadians(bearingDeg % 360.0)
        val angle = meters / EARTH_RADIUS_METERS
        val sinLat = sin(latitude)
        val cosLat = cos(latitude)
        val sinLng = sin(longitude)
        val cosLng = cos(longitude)
        val north = cos(bearing)
        val east = sin(bearing)
        val cosAngle = cos(angle)
        val sinAngle = sin(angle)
        // 以位置、局部正北和正东单位向量作旋转，避免极点经度式相减后退化为 0/0。
        // 精确极点的局部方向沿输入经线定义；北极向南即沿该经线离开极点。
        val x = cosAngle * cosLat * cosLng + sinAngle * (-north * sinLat * cosLng - east * sinLng)
        val y = cosAngle * cosLat * sinLng + sinAngle * (-north * sinLat * sinLng + east * cosLng)
        val z = cosAngle * sinLat + sinAngle * north * cosLat
        val nextLat = atan2(z, Math.hypot(x, y))
        val nextLng = atan2(y, x)
        return Math.toDegrees(nextLat) to normalizeLongitude(Math.toDegrees(nextLng))
    }

    /** 两点间的方位角（度，正北为 0）。 */
    fun bearingTo(lat1: Double, lng1: Double, lat2: Double, lng2: Double): Float =
        initialBearingDegrees(lat1, lng1, lat2, lng2).toFloat()

    private fun initialBearingDegrees(lat1: Double, lng1: Double, lat2: Double, lng2: Double): Double {
        require(validCoordinate(lat1, lng1) && validCoordinate(lat2, lng2)) { "坐标必须是有效的有限经纬度" }
        val latA = Math.toRadians(lat1)
        val latB = Math.toRadians(lat2)
        val dLng = Math.toRadians(normalizeLongitude(lng2 - lng1))
        val y = sin(dLng) * cos(latB)
        val x = cos(latA) * sin(latB) - sin(latA) * cos(latB) * cos(dLng)
        // 重合点无朝向；精确对跖点有无穷条最短路径，固定选向北的一条以保持可重复。
        if (Math.hypot(x, y) < 1e-12) return 0.0
        val deg = Math.toDegrees(atan2(y, x))
        return (deg + 360) % 360
    }

    private fun validCoordinate(lat: Double, lng: Double): Boolean =
        lat.isFinite() && lng.isFinite() && lat in -90.0..90.0 && lng in -180.0..180.0

    private fun normalizeLongitude(lng: Double): Double = ((lng + 180.0) % 360.0 + 360.0) % 360.0 - 180.0
}
