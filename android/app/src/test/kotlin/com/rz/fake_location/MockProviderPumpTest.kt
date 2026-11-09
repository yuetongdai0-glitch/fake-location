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
            if (provider == "network" && networkFails) throw IllegalArgumentException("provider removed")
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

    @Test fun transientPublishFailureRetainsRegisteredProviderOnOldSystems() {
        val installed = mutableSetOf<String>()
        var registrationCalls = 0
        var failNetworkOnce = false
        val pump = MockProviderPump(listOf("gps", "network"), { provider ->
            registrationCalls++
            if (!installed.add(provider)) throw IllegalArgumentException("already installed")
        }, { provider ->
            if (provider !in installed) throw IllegalArgumentException("missing")
            if (provider == "network" && failNetworkOnce) {
                failNetworkOnce = false
                throw IllegalStateException("temporary failure")
            }
        })
        assertEquals(listOf("gps", "network"), pump.push(0, 1000))
        failNetworkOnce = true
        assertEquals(listOf("gps"), pump.push(100, 1100))
        assertEquals(1000L, pump.lastPushAt["network"])
        assertEquals(listOf("gps", "network"), pump.push(1100, 2100))
        assertEquals(2, registrationCalls)
        assertTrue(pump.errors.isEmpty())
    }

    @Test fun existingOldSystemProviderIsReusedOnlyAfterActualPublishSucceeds() {
        var publishes = 0
        val pump = MockProviderPump(listOf("gps"), {
            throw IllegalArgumentException("localized existing provider")
        }, { publishes++ })
        assertEquals(listOf("gps"), pump.push(0, 1000))
        assertEquals(1, publishes)
        assertEquals(1000L, pump.lastPushAt["gps"])
        assertEquals(listOf("gps"), pump.push(100, 1100))
        assertEquals(2, publishes)
    }

    @Test fun registrationFailureCannotPassByIgnoringFailedFallbackPublish() {
        val pump = MockProviderPump(listOf("network"), {
            throw IllegalArgumentException("unsupported")
        }, { throw IllegalArgumentException("not a test provider") })
        assertTrue(pump.push(0, 1000).isEmpty())
        assertTrue(pump.lastPushAt.isEmpty())
        assertNotNull(pump.errors["network"])
    }

    @Test fun revokedAuthorizationStopsSilentSuccessAndRecoversWithoutReregistering() {
        var allowed = true
        var registrationCalls = 0
        var publishes = 0
        val pump = MockProviderPump(
            listOf("gps", "network", "fused"),
            { registrationCalls++ },
            { publishes++ },
            isAuthorized = { allowed },
        )
        assertEquals(3, pump.push(0, 1000).size)
        allowed = false
        assertTrue(pump.push(100, 1100).isEmpty())
        assertEquals(3, publishes)
        assertTrue(pump.errors.values.all { it.contains("模拟位置授权已失效") })
        assertTrue(pump.lastPushAt.values.all { it == 1000L })
        assertTrue(pump.push(500, 1500).isEmpty())
        allowed = true
        assertEquals(3, pump.push(600, 1600).size)
        assertEquals(3, registrationCalls)
        assertEquals(6, publishes)
        assertTrue(pump.errors.isEmpty())
        assertTrue(pump.lastPushAt.values.all { it == 1600L })
    }
}
