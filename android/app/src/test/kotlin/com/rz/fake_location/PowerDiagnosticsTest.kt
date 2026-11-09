package com.rz.fake_location

import org.junit.Assert.*
import org.junit.Test

/** 兼容旧系统并区分未知/正常状态，防止检测面板把读取失败显示为未受限制。 */
class PowerDiagnosticsTest {
    @Test fun unsupportedApisAreUnknownAndNeverInvoked() {
        val status = PowerDiagnostics.snapshot(
            22,
            ignoringBatteryOptimizations = { error("旧系统不应访问电池优化接口") },
            powerSaveMode = { true },
            backgroundRestricted = { error("旧系统不应访问后台限制接口") },
        )
        assertNull(status["ignoringBatteryOptimizations"])
        assertNull(status["backgroundRestricted"])
        assertEquals(true, status["powerSaveMode"])
        assertEquals(emptyMap<String, String>(), status["errors"])
    }

    @Test fun oneFailedReadDoesNotHideOtherRestrictions() {
        val status = PowerDiagnostics.snapshot(
            36,
            ignoringBatteryOptimizations = { throw SecurityException("接口不可读") },
            powerSaveMode = { false },
            backgroundRestricted = { true },
        )
        assertNull(status["ignoringBatteryOptimizations"])
        assertEquals(false, status["powerSaveMode"])
        assertEquals(true, status["backgroundRestricted"])
        assertEquals(
            mapOf("ignoringBatteryOptimizations" to "读取后台状态失败：权限不足，请检查系统授权"),
            status["errors"],
        )
    }

    @Test fun missingSystemServiceRemainsUnknown() {
        val status = PowerDiagnostics.snapshot(36, { null }, { false }, { false })
        assertNull(status["ignoringBatteryOptimizations"])
        assertEquals(false, status["backgroundRestricted"])
        assertEquals(
            mapOf("ignoringBatteryOptimizations" to "系统未提供此状态"), status["errors"],
        )
    }
}
