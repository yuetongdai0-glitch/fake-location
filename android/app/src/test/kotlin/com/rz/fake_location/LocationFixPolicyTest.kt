package com.rz.fake_location

import org.junit.Assert.*
import org.junit.Test

class LocationFixPolicyTest {
    @Test fun onlyRecentMockReadbackNearTargetCountsAsConfirmed() {
        fun matches(age: Long = 100L, mock: Boolean = true, lat: Double = 31.23) =
            LocationFixPolicy.matchesMockTarget(lat, 121.47, 5f, age, mock, 31.23, 121.47)
        assertTrue(matches())
        assertFalse(matches(mock = false))
        assertFalse(matches(age = -1L))
        assertFalse(matches(age = 5000L))
        assertFalse(matches(lat = 29.73))
        assertFalse(matches(lat = Double.NaN))
    }

    @Test fun futureAndMissingFixTimesDoNotBecomeFresh() {
        assertEquals(-1L, LocationFixPolicy.ageMillis(2_000_000_000L, 0L))
        assertEquals(-1L, LocationFixPolicy.ageMillis(2_000_000_000L, 2_000_000_001L))
        assertEquals(500L, LocationFixPolicy.ageMillis(2_000_000_000L, 1_500_000_000L))
    }

    @Test fun rejectsStaleInvalidAndDelayedMockFixes() {
        fun usable(age: Long = 100L, lat: Double = 0.0, accuracy: Float = 5f,
                   mock: Boolean = false, real: Boolean = false) =
            LocationFixPolicy.usable(lat, 180.0, accuracy, age, mock, real)
        assertTrue(usable())
        assertFalse(usable(age = -1L))
        assertFalse(usable(age = 60_001L))
        assertFalse(usable(lat = Double.NaN))
        assertFalse(usable(accuracy = Float.NaN))
        assertFalse(usable(mock = true, real = true))
        assertTrue(usable(mock = true))
    }
}
