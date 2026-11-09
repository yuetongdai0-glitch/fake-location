package com.rz.fake_location

/** 独立维护每个定位源的接管与重试；网络源失败不能被 GPS 的成功掩盖或永久跳过。 */
internal class MockProviderPump(
    val providers: List<String>,
    private val register: (String) -> Unit,
    private val publish: (String) -> Unit,
    private val reportFailure: (String, Exception) -> Unit = { _, _ -> },
) {
    private val registered = mutableSetOf<String>()
    private val retryAfter = mutableMapOf<String, Long>()
    val errors = mutableMapOf<String, String>()
    val lastPushAt = mutableMapOf<String, Long>()

    /** 推送全部目标源，失败源最多每秒重试一次，已成功的源继续正常更新。 */
    fun push(elapsedMs: Long, timestampMs: Long): List<String> {
        val successful = mutableListOf<String>()
        for (provider in providers) {
            if (elapsedMs < (retryAfter[provider] ?: 0L)) continue
            try {
                if (provider !in registered) {
                    register(provider)
                    registered.add(provider)
                }
                publish(provider)
                errors.remove(provider)
                retryAfter.remove(provider)
                lastPushAt[provider] = timestampMs
                successful.add(provider)
            } catch (failure: Exception) {
                reportFailure(provider, failure)
                registered.remove(provider)
                errors[provider] = NativeErrorMessages.describe("推送定位失败", failure)
                retryAfter[provider] = elapsedMs + 1000L
            }
        }
        return successful
    }
}
