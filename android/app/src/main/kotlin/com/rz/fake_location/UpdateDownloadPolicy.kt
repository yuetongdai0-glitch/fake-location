package com.rz.fake_location

import java.net.URI

/** 更新来源和长度的纯校验规则，与 Flutter 清单校验使用同一发布仓库。 */
internal object UpdateDownloadPolicy {
    const val MAX_BYTES = 250L * 1024 * 1024

    /** 同一发行仓库的两个固定入口，缓存旧包也必须按原清单的完整摘要重新核验。 */
    fun downloadSources(initial: String, versionCode: Long): List<String> {
        val api = "https://api.github.com/repos/yuetongdai0-glitch/fake-location-releases/contents/releases/android/latest.apk?ref=main"
        val alternate = if (URI(initial).host == "raw.githubusercontent.com") {
            "https://yuetongdai0-glitch.github.io/fake-location-releases/releases/android/latest.apk?v=$versionCode"
        } else {
            "https://raw.githubusercontent.com/yuetongdai0-glitch/fake-location-releases/main/releases/android/latest.apk?v=$versionCode"
        }
        return listOf(initial, alternate, api).distinct()
    }

    /** 首跳只允许本项目发行文件；后续签名附件 CDN 不能成为任意清单来源。 */
    fun allowedUrl(raw: String, redirect: Boolean = false): Boolean = try {
        val uri = URI(raw)
        val host = uri.host?.lowercase()
        val path = uri.path ?: ""
        val safe = uri.scheme.equals("https", true) && uri.rawUserInfo == null &&
            uri.rawFragment == null && uri.port in listOf(-1, 443) &&
            uri.normalize().rawPath == uri.rawPath &&
            path.split('/').none { it == "." || it == ".." } &&
            '\\' !in path && !Regex("(?i)%2f|%5c").containsMatchIn(uri.rawPath ?: "")
        safe && when (host) {
            "yuetongdai0-glitch.github.io" -> path == "/fake-location-releases/releases/android/latest.apk"
            "raw.githubusercontent.com" -> path in listOf(
                "/yuetongdai0-glitch/fake-location-releases/main/releases/android/latest.apk",
                "/yuetongdai0-glitch/fake-location-releases/refs/heads/main/releases/android/latest.apk",
            )
            "github.com" -> path in listOf(
                "/yuetongdai0-glitch/fake-location-releases/raw/main/releases/android/latest.apk",
                "/yuetongdai0-glitch/fake-location-releases/raw/refs/heads/main/releases/android/latest.apk",
            ) || Regex("^/yuetongdai0-glitch/fake-location-releases/releases/download/[^/]+/[^/]+\\.apk$").matches(path)
            "api.github.com" -> path == "/repos/yuetongdai0-glitch/fake-location-releases/contents/releases/android/latest.apk" &&
                uri.rawQuery?.split('&')?.count { it == "ref=main" } == 1 &&
                uri.rawQuery?.split('&')?.count { it.startsWith("_=") } in 0..1 &&
                uri.rawQuery?.split('&')?.all { part ->
                    part == "ref=main" || Regex("^_=[0-9]+$").matches(part)
                } == true
            "release-assets.githubusercontent.com", "objects.githubusercontent.com" -> redirect
            else -> false
        }
    } catch (_: Exception) { false }

    /** 已知服务器长度、清单长度均必须精确相等，缺省长度仍受总量上限保护。 */
    fun validLength(received: Long, declared: Long, expected: Long): Boolean =
        received in 1..MAX_BYTES && (declared < 0 || declared == received) &&
            (expected < 0 || expected == received)
}

/** 经过桥边界验证的当前应用升级目标，不存设备标识或认证信息。 */
internal data class UpdateRequest(
    val packageId: String,
    val versionName: String,
    val versionCode: Long,
    val apkUrl: String,
    val sha256: String,
    val minSdk: Int,
    val apkBytes: Long,
) {
    fun fields(): Map<String, Any> = mapOf(
        "packageId" to packageId, "versionName" to versionName, "versionCode" to versionCode,
        "apkUrl" to apkUrl, "sha256" to sha256, "minSdk" to minSdk, "apkBytes" to apkBytes,
    )

    companion object {
        /** 外部参数必须完整、同包且递增，不能将错误类型转换成可用版本。 */
        fun parse(raw: Map<*, *>, packageId: String, installed: Long, sdk: Int): UpdateRequest {
            fun integer(key: String): Long? {
                val value = raw[key]
                return if (value is Int) value.toLong() else value as? Long
            }
            val code = integer("versionCode")
            val name = raw["versionName"] as? String ?: ""
            val url = raw["apkUrl"] as? String
            val digest = raw["sha256"] as? String
            val minimum = integer("minSdk") ?: 1L
            val bytes = if (raw["apkBytes"] == null) -1L else integer("apkBytes") ?: 0L
            if (raw["packageId"] != packageId || code == null || code <= installed || code > Int.MAX_VALUE ||
                name.isBlank() || url == null || !UpdateDownloadPolicy.allowedUrl(url) ||
                digest == null || !Regex("(?i)^[0-9a-f]{64}$").matches(digest) ||
                minimum !in 1L..sdk.toLong() || (bytes != -1L && bytes !in 1..UpdateDownloadPolicy.MAX_BYTES)
            ) throw AppOperationException("更新信息无效")
            return UpdateRequest(packageId, name, code, url, digest.lowercase(), minimum.toInt(), bytes)
        }
    }
}
