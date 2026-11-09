package com.rz.fake_location

import org.junit.After
import org.junit.Assert.*
import org.junit.Test

/** 原生入口拒绝坏路线时必须保留旧路线，合法零坐标同样需要可用。 */
class RouteEngineTest {
    @After fun stop() = RouteEngine.stop()

    @Test fun invalidRouteDoesNotCorruptRunningRoute() {
        assertTrue(RouteEngine.start(listOf(0.0 to 0.0, 0.0 to 0.001), 1.0, "once"))
        assertFalse(RouteEngine.start(listOf(1.0 to 1.0, 1.0 to 1.0), 1.0, "once"))
        assertFalse(RouteEngine.start(listOf(Double.NaN to 1.0, 1.0 to 2.0), 1.0, "once"))
        assertFalse(RouteEngine.start(listOf(91.0 to 1.0, 1.0 to 2.0), 1.0, "once"))
        RouteEngine.tick(1000)
        assertTrue(RouteEngine.active)
        // 球面直达的三角函数会产生浮点舍入，本测试关心旧路线不被破坏。
        assertEquals(0.0, RouteEngine.latitude, 1e-12)
        assertTrue(RouteEngine.longitude in 0.0..0.001)
        assertEquals(1.0, RouteEngine.travelled, 0.0)
    }

    @Test fun rejectsNonfiniteSpeedAndUnknownPlaybackMode() {
        val points = listOf(0.0 to 0.0, 0.0 to 0.001)
        assertFalse(RouteEngine.start(points, Double.NaN, "once"))
        assertFalse(RouteEngine.start(points, Double.POSITIVE_INFINITY, "once"))
        assertFalse(RouteEngine.start(points, 1.0, "invalid"))
        assertTrue(RouteEngine.start(points, 1.0, "once"))
        RouteEngine.setSpeed(Double.NaN)
        assertEquals(1.0, RouteEngine.speed, 0.0)
    }
}
