package com.rz.fake_location

import org.junit.Assert.*
import org.junit.Test

/** 验证多个客户端依赖不同定位源时，部分失败不会形成永久漏接管。 */
class MockProviderPumpTest {
    @Test fun retriesInitiallyUnavailableNetworkWithoutInterruptingGps() {
        val registrations = mutableListOf<String>()
        val published = mutableListOf<String>()
        var networkAvailable = false
        val pump = MockProviderPump(listOf("gps", "network", "fused"), { provider ->
            registrations.add(provider)
            if (provider == "network" && !networkAvailable) error("network unavailable")
        }, published::add)

        assertEquals(listOf("gps", "fused"), pump.push(0, 1000))
        assertEquals("推送定位失败：系统状态暂不可用，请稍后重试", pump.errors["network"])
        networkAvailable = true
        pump.push(500, 1500)
        assertEquals(1, registrations.count { it == "network" })
        assertEquals(listOf("gps", "network", "fused"), pump.push(1000, 2000))
        assertEquals(1, registrations.count { it == "gps" })
        assertTrue(pump.errors.isEmpty())
        assertEquals(2000L, pump.lastPushAt["network"])
        assertEquals(3, published.count { it == "gps" })
    }

    @Test fun reclaimsProviderLostAfterSwitchingClients() {
        var networkFails = false
        var networkRegistrations = 0
        val pump = MockProviderPump(listOf("gps", "network"), { provider ->
            if (provider == "network") networkRegistrations++
        }, { provider ->
            if (provider == "network" && networkFails) error("provider removed")
        })

        assertEquals(2, pump.push(0, 1000).size)
        networkFails = true
        assertEquals(listOf("gps"), pump.push(100, 1100))
        assertEquals(1000L, pump.lastPushAt["network"])
        networkFails = false
        assertEquals(2, pump.push(1100, 2100).size)
        assertEquals(2, networkRegistrations)
        assertTrue(pump.errors.isEmpty())
    }

    @Test fun reportsTotalFailureAndRecoversAllSources() {
        var allowed = false
        val pump = MockProviderPump(listOf("gps", "network", "fused"), {
            if (!allowed) throw SecurityException("mock permission denied")
        }, {})
        assertTrue(pump.push(0, 1000).isEmpty())
        assertEquals(3, pump.errors.size)
        assertTrue(pump.lastPushAt.isEmpty())
        allowed = true
        assertEquals(3, pump.push(1000, 2000).size)
        assertTrue(pump.errors.isEmpty())
    }
}
