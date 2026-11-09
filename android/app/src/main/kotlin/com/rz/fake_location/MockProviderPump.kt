package com.rz.fake_location

/** 独立维护每个定位源的接管与重试；网络源失败不能被 GPS 的成功掩盖或永久跳过。 */
internal class MockProviderPump(
    val providers: List<String>,
    private val register: (String) -> Unit,
    private val publish: (String) -> Unit,
    private val reportFailure: (String, Exception) -> Unit = { _, _ -> },
    private val isAuthorized: () -> Boolean = { true },
) {
    private val registered = mutableSetOf<String>()
    private val retryAfter = mutableMapOf<String, Long>()
    val errors = mutableMapOf<String, String>()
    val lastPushAt = mutableMapOf<String, Long>()

    /** 推送全部目标源，失败源最多每秒重试一次，已成功的源继续正常更新。 */
    fun push(elapsedMs: Long, timestampMs: Long): List<String> {
        val successful = mutableListOf<String>()
        // 某些系统在模拟授权失效时静默忽略测试源调用，不能据“没有异常”继续累计成功。
        if (!isAuthorized()) {
            for (provider in providers) {
                errors[provider] = "推送定位失败：模拟位置授权已失效，请重新选择本应用"
            }
            retryAfter.clear()
            return successful
        }
        for (provider in providers) {
            if (elapsedMs < (retryAfter[provider] ?: 0L)) continue
            try {
                var publishedDuringRegistration = false
                if (provider !in registered) {
                    try {
                        register(provider)
                    } catch (_: IllegalArgumentException) {
                        // 旧系统已有测试源时拒绝重复注册。保留原源并实际推送验证，
                        // 不匹配厂商异常文案，也不先移除测试源造成真实位置短暂泄漏。
                        publish(provider)
                        publishedDuringRegistration = true
                    }
                    registered.add(provider)
                }
                if (!publishedDuringRegistration) publish(provider)
                errors.remove(provider)
                retryAfter.remove(provider)
                lastPushAt[provider] = timestampMs
                successful.add(provider)
            } catch (failure: Exception) {
                reportFailure(provider, failure)
                // 网络/权限等暂时失败不等于测试源消失。先重推原源，明确缺源时才重新注册。
                if (failure is IllegalArgumentException) registered.remove(provider)
                errors[provider] = NativeErrorMessages.describe("推送定位失败", failure)
                retryAfter[provider] = elapsedMs + 1000L
            }
        }
        return successful
    }
}
