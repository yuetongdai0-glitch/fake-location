package com.rz.fake_location

import org.junit.After
import org.junit.Assert.*
import org.junit.Test
import kotlin.math.abs
import kotlin.math.roundToLong

/** 定量覆盖路线跨经线、回程、暂停变速与边界，而不复制生产计算公式。 */
class RouteGeometryTest {
    @After fun stop() = RouteEngine.stop()

    @Test fun crossesDateLineAlongShortArc() {
        assertEquals(22239.016, RouteEngine.distance(0.0, 179.9, 0.0, -179.9), 0.01)
        assertTrue(RouteEngine.start(listOf(0.0 to 179.9, 0.0 to -179.9), 100.0, "once"))
        RouteEngine.tick((RouteEngine.total / 2 / 100 * 1000).roundToLong())
        assertTrue(abs(RouteEngine.longitude) > 179.999)
        assertEquals(0.0, RouteEngine.latitude, 1e-10)
        assertEquals(90.0, RouteEngine.bearing.toDouble(), 1e-5)
    }

    @Test fun openLoopTravelsBackInsteadOfTeleporting() {
        val leg = RouteEngine.distance(0.0, 0.0, 0.0, 0.001)
        assertTrue(RouteEngine.start(listOf(0.0 to 0.0, 0.0 to 0.001), 1.0, "loop"))
        assertEquals(leg * 2, RouteEngine.total, 1e-9)
        RouteEngine.tick((leg * 1000).roundToLong())
        assertEquals(0.001, RouteEngine.longitude, 1e-8)
        val before = RouteEngine.longitude
        RouteEngine.tick(1000)
        assertTrue(RouteEngine.longitude < before)
        assertTrue(RouteEngine.longitude > 0.0009)
        assertEquals(270.0, RouteEngine.bearing.toDouble(), 1e-4)
    }

    @Test fun closedLoopDoesNotAddAnExtraLap() {
        val points = listOf(0.0 to 0.0, 0.0 to 0.001, 0.0 to 0.0)
        assertTrue(RouteEngine.start(points, 1.0, "loop"))
        assertEquals(RouteEngine.distance(0.0, 0.0, 0.0, 0.001) * 2, RouteEngine.total, 1e-9)
    }

    @Test fun pingpongReturnBearingMatchesActualMovement() {
        assertTrue(RouteEngine.start(listOf(0.0 to 0.0, 0.0 to 0.001), 1.0, "pingpong"))
        RouteEngine.tick((RouteEngine.total * 1.5 * 1000).roundToLong())
        assertEquals(0.0005, RouteEngine.longitude, 1e-8)
        assertEquals(270.0, RouteEngine.bearing.toDouble(), 1e-4)
        assertEquals(0.75, RouteEngine.progress(), 1e-5)
    }

    @Test fun duplicatePointsDoNotCreateUndefinedHeadingOrLength() {
        assertTrue(RouteEngine.start(listOf(0.0 to 0.0, 0.0 to 0.0, 0.0 to 0.001, 0.0 to 0.001), 1.0, "once"))
        assertEquals(90.0, RouteEngine.bearing.toDouble(), 1e-4)
        RouteEngine.tick(1000)
        assertEquals(1.0, RouteEngine.travelled, 1e-12)
        assertTrue(RouteEngine.longitude > 0)
    }

    @Test fun negativeTimeDoesNotMoveAndPausedTimeDoesNotAccumulate() {
        assertTrue(RouteEngine.start(listOf(0.0 to 0.0, 0.0 to 0.01), 1.0, "once"))
        assertFalse(RouteEngine.tick(-1000))
        assertFalse(RouteEngine.tick(0))
        assertEquals(0.0, RouteEngine.travelled, 0.0)
        RouteEngine.tick(1000)
        RouteEngine.pause()
        RouteEngine.tick(60000)
        assertEquals(1.0, RouteEngine.travelled, 0.0)
        assertEquals(1.0, RouteEngine.elapsedSeconds(), 0.0)
        RouteEngine.resume()
        RouteEngine.setSpeed(2.0)
        RouteEngine.tick(1000)
        assertEquals(3.0, RouteEngine.travelled, 0.0)
        assertEquals(2.0, RouteEngine.elapsedSeconds(), 0.0)
    }

    @Test fun completionKeepsTheExactEndpointAndClampsMovingTime() {
        assertTrue(RouteEngine.start(listOf(29.75 to 106.58, 29.751 to 106.582), 1.4, "once"))
        val expectedSeconds = RouteEngine.total / 1.4
        RouteEngine.tick(100000000)
        assertFalse(RouteEngine.active)
        assertEquals(29.751, RouteEngine.latitude, 0.0)
        assertEquals(106.582, RouteEngine.longitude, 0.0)
        assertEquals(RouteEngine.total, RouteEngine.travelled, 0.0)
        assertEquals(1.0, RouteEngine.progress(), 0.0)
        assertEquals(expectedSeconds, RouteEngine.elapsedSeconds(), 1e-9)
        assertFalse(RouteEngine.tick(1000))
    }

    @Test fun offsetsRemainFiniteAtPolesAndWrapLongitude() {
        for (lat in listOf(-90.0, -89.999, 89.999, 90.0)) {
            val point = RouteEngine.offset(lat, 179.999, 90.0, 1000.0)
            assertTrue(point.first.isFinite() && point.second.isFinite())
            assertTrue(point.first in -90.0..90.0 && point.second in -180.0..180.0)
            assertEquals(1000.0, RouteEngine.distance(lat, 179.999, point.first, point.second), 0.001)
        }
        val point = RouteEngine.offset(0.0, 179.999, 90.0, 1000.0)
        assertTrue(point.second < -179.99)
    }

    @Test fun routesLeavingEitherPoleKeepTheDestinationMeridian() {
        for (pole in listOf(-90.0, 90.0)) {
            for (meridian in listOf(0.0, 45.0, -135.0)) {
                for (poleFrameMeridian in listOf(meridian, 73.0)) {
                    val destination = if (pole > 0) 80.0 else -80.0
                    val distance = RouteEngine.distance(pole, poleFrameMeridian, destination, meridian)
                    assertTrue(RouteEngine.start(listOf(pole to poleFrameMeridian, destination to meridian), distance / 10000.0, "once"))
                    // 总时长精确一万秒；极点输入经度只定义方向框架，不能改变前往目标的实际路径。
                    RouteEngine.tick(5000000)
                    assertEquals(if (pole > 0) 85.0 else -85.0, RouteEngine.latitude, 1e-10)
                    assertEquals(meridian, RouteEngine.longitude, 1e-10)
                    assertEquals(if (pole > 0) 180.0 else 0.0, RouteEngine.bearing.toDouble(), 1e-5)
                }
            }
        }
    }

    @Test fun poleOffsetsUseTheInputMeridianAsTheLocalNorthEastFrame() {
        val fiveDegrees = RouteEngine.EARTH_RADIUS_METERS * Math.PI / 36.0
        val bearings = listOf(0.0, 90.0, 180.0, 270.0)
        for ((pole, expectedLongitudes) in listOf(
            90.0 to listOf(-180.0, 90.0, 0.0, -90.0),
            -90.0 to listOf(0.0, 90.0, -180.0, -90.0),
        )) {
            for ((bearing, expectedLongitude) in bearings.zip(expectedLongitudes)) {
                val moved = RouteEngine.offset(pole, 0.0, bearing, fiveDegrees)
                assertEquals(if (pole > 0) 85.0 else -85.0, moved.first, 1e-10)
                assertEquals(expectedLongitude, moved.second, 1e-10)
            }
        }
    }

    @Test fun exactAntipodalRouteUsesDeterministicNorthwardGreatCircle() {
        // 对跖点没有唯一最短路径，固定按起点局部正北方向出发。
        for ((start, end, midpoint) in listOf(
            Triple(0.0 to 0.0, 0.0 to 180.0, 90.0 to 0.0),
            Triple(90.0 to 0.0, -90.0 to 0.0, 0.0 to -180.0),
        )) {
            val distance = RouteEngine.distance(start.first, start.second, end.first, end.second)
            assertTrue(RouteEngine.start(listOf(start, end), distance / 100000.0, "once"))
            RouteEngine.tick(50000000)
            assertEquals(midpoint.first, RouteEngine.latitude, 1e-10)
            if (kotlin.math.abs(midpoint.first) < 90.0) assertEquals(midpoint.second, RouteEngine.longitude, 1e-10)
        }
    }

    @Test fun antipodalAndAlmostAntipodalRoutesHaveFiniteMidpoints() {
        for (end in listOf(0.0 to 180.0, 0.000001 to 179.999999)) {
            assertTrue(RouteEngine.start(listOf(0.0 to 0.0, end), 300.0, "once"))
            val half = RouteEngine.total / 2
            RouteEngine.tick((half / 300 * 1000).roundToLong())
            assertTrue(RouteEngine.latitude.isFinite() && RouteEngine.longitude.isFinite())
            assertEquals(half, RouteEngine.distance(0.0, 0.0, RouteEngine.latitude, RouteEngine.longitude), 0.2)
        }
    }

    @Test fun northSouthLengthUsesTheSameSphereAsEastWest() {
        assertEquals(111195.0802, RouteEngine.distance(0.0, 0.0, 1.0, 0.0), 0.001)
        assertEquals(111195.0802, RouteEngine.distance(0.0, 0.0, 0.0, 1.0), 0.001)
        assertEquals(0.0, RouteEngine.distance(90.0, -180.0, 90.0, 180.0), 1e-6)
    }

    @Test fun outOfRangeSpeedIsRejectedWithoutChangingTheExistingRoute() {
        val points = listOf(0.0 to 0.0, 0.0 to 0.001)
        assertTrue(RouteEngine.start(points, 0.1, "once"))
        RouteEngine.tick(1000)
        assertEquals(0.1, RouteEngine.travelled, 1e-12)
        assertFalse(RouteEngine.start(points, 0.01, "once"))
        assertFalse(RouteEngine.start(points, 300.001, "once"))
        RouteEngine.setSpeed(0.0)
        RouteEngine.setSpeed(0.01)
        RouteEngine.setSpeed(300.001)
        assertEquals(0.1, RouteEngine.speed, 0.0)
        RouteEngine.setSpeed(0.2)
        RouteEngine.tick(1000)
        assertEquals(0.3, RouteEngine.travelled, 1e-12)
    }
}
