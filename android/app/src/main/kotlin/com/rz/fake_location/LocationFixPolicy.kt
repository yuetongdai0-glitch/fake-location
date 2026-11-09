package com.rz.fake_location

/** 以同一次开机的单调时间判断定位是否可用，避免改系统时间后旧缓存被当成新位置。 */
internal object LocationFixPolicy {
    const val MAX_AGE_MS = 60_000L

    /** 未来时间、缺失时间均不可作为近期缓存，不能夹成零秒后误报新鲜。 */
    fun ageMillis(nowNanos: Long, fixNanos: Long): Long =
        if (fixNanos <= 0L || nowNanos < fixNanos) -1L else (nowNanos - fixNanos) / 1_000_000L

    /** 系统缓存与实时回调共用输入边界；停止模拟后的真实定位请求排除延迟到达的模拟回调。 */
    fun usable(
        latitude: Double,
        longitude: Double,
        accuracy: Float,
        ageMs: Long,
        mock: Boolean,
        requireReal: Boolean,
    ): Boolean = latitude.isFinite() && longitude.isFinite() &&
        latitude in -90.0..90.0 && longitude in -180.0..180.0 &&
        accuracy.isFinite() && accuracy >= 0f && ageMs in 0..MAX_AGE_MS &&
        (!requireReal || !mock)
}
