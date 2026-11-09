package com.rz.fake_location

import org.junit.Assert.*
import org.junit.Test

/** 手动位移速度必须跟随近期输入，松杆不应等待定位服务的下一次移动指令。 */
class ManualMotionStateTest {
    @Test fun speedAndBearingFollowTheLatestCoordinateUpdate() {
        val motion = ManualMotionState()
        assertTrue(motion.update(1.4, -90.0, 0L))
        assertEquals(1.4, motion.speedAt(100L), 0.0)
        assertEquals(270f, motion.bearing, 0f)
        assertTrue(motion.update(0.0, 270.0, 200L))
        assertEquals(0.0, motion.speedAt(200L), 0.0)
    }

    @Test fun staleOrInvalidClockDoesNotKeepReportingMovement() {
        val motion = ManualMotionState()
        assertEquals(0.0, motion.speedAt(100L), 0.0)
        assertTrue(motion.update(5.0, 90.0, 100L))
        assertEquals(5.0, motion.speedAt(1100L), 0.0)
        assertEquals(0.0, motion.speedAt(1101L), 0.0)
        assertEquals(0.0, motion.speedAt(99L), 0.0)
    }

    @Test fun invalidUpdatesDoNotReplaceValidMotion() {
        val motion = ManualMotionState()
        assertTrue(motion.update(2.0, 180.0, 100L))
        assertFalse(motion.update(Double.NaN, 0.0, 100L))
        assertFalse(motion.update(-1.0, 0.0, 100L))
        assertFalse(motion.update(300.001, 0.0, 100L))
        assertFalse(motion.update(1.0, Double.POSITIVE_INFINITY, 100L))
        assertFalse(motion.update(1.0, 0.0, -1L))
        assertEquals(2.0, motion.speedAt(200L), 0.0)
        assertEquals(180f, motion.bearing, 0f)
    }

    @Test fun newRouteOrFixedPointClearsPreviousJoystickMetadata() {
        val motion = ManualMotionState()
        assertTrue(motion.update(3.0, 90.0, 100L))
        motion.reset()
        assertEquals(0.0, motion.speedAt(200L), 0.0)
        assertEquals(0f, motion.bearing, 0f)
    }
}
