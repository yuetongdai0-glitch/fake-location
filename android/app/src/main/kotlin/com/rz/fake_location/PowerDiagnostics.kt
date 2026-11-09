package com.rz.fake_location

/** 读取影响后台模拟的系统限制；不支持或读取失败必须保持未知，不能伪报未受限制。 */
internal object PowerDiagnostics {
    /** 每项独立读取，某个 ROM 的接口异常不应掩盖其余可用状态。 */
    fun snapshot(
        sdkInt: Int,
        ignoringBatteryOptimizations: () -> Boolean?,
        powerSaveMode: () -> Boolean?,
        backgroundRestricted: () -> Boolean?,
        reportFailure: (String, Exception) -> Unit = { _, _ -> },
    ): Map<String, Any?> {
        val errors = mutableMapOf<String, String>()
        fun read(name: String, minSdk: Int, reader: () -> Boolean?): Boolean? {
            if (sdkInt < minSdk) return null
            return try {
                reader().also { if (it == null) errors[name] = "系统未提供此状态" }
            } catch (failure: Exception) {
                reportFailure(name, failure)
                errors[name] = NativeErrorMessages.describe("读取后台状态失败", failure)
                null
            }
        }
        return mapOf(
            "sdkInt" to sdkInt,
            "ignoringBatteryOptimizations" to read(
                "ignoringBatteryOptimizations", 23, ignoringBatteryOptimizations,
            ),
            "powerSaveMode" to read("powerSaveMode", 21, powerSaveMode),
            "backgroundRestricted" to read("backgroundRestricted", 28, backgroundRestricted),
            "errors" to errors,
        )
    }
}
