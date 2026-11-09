package com.rz.fake_location

/** 摇杆只报告近期坐标更新对应的速度，避免松杆或页面失活后留下永久的移动状态。 */
internal class ManualMotionState {
    var bearing = 0f
        private set
    private var speed = 0.0
    private var updatedAt = -1L

    /** 与原生入口共用边界；非法参数不覆盖上一次有效状态。 */
    fun update(speedMetersPerSecond: Double, bearingDegrees: Double, elapsedMs: Long): Boolean {
        if (!speedMetersPerSecond.isFinite() || speedMetersPerSecond !in 0.0..300.0 ||
            !bearingDegrees.isFinite() || elapsedMs < 0L
        ) return false
        speed = speedMetersPerSecond
        bearing = (((bearingDegrees % 360.0) + 360.0) % 360.0).toFloat()
        updatedAt = elapsedMs
        return true
    }

    /** 停止刷新超过一秒或时钟无效时只清除速度，位置仍由服务持续投递。 */
    fun speedAt(elapsedMs: Long): Double =
        if (updatedAt < 0L || elapsedMs < updatedAt || elapsedMs - updatedAt > 1000L) 0.0 else speed

    /** 新定点或新路线不继承前一次摇杆的移动元数据。 */
    fun reset() {
        speed = 0.0
        bearing = 0f
        updatedAt = -1L
    }
}
