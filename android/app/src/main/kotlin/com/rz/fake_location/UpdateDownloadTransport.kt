package com.rz.fake_location

import java.io.File
import java.io.FileOutputStream
import java.io.InterruptedIOException
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest

/** 下载传输独立于安卓界面，可用真实文件和可控连接验证重定向、截断、取消。 */
internal class UpdateDownloadTransport(
    private val open: (URL) -> HttpURLConnection = { it.openConnection() as HttpURLConnection },
    private val nowMs: () -> Long = { System.nanoTime() / 1_000_000L },
) {
    /** 每跳检查来源；取消会同时断开连接，旧任务不得继续写入或进入安装。 */
    fun download(
        request: UpdateRequest,
        output: File,
        cancelled: () -> Boolean,
        connectionChanged: (HttpURLConnection?) -> Unit,
        progress: (Long, Long) -> Unit,
        verifying: () -> Unit,
        budgetMs: Long = 10 * 60_000L,
    ) {
        val deadline = nowMs() + budgetMs.coerceAtLeast(0)
        fun check() {
            if (cancelled()) throw InterruptedIOException("下载已取消")
            if (nowMs() >= deadline) throw AppOperationException("下载超时，请重试")
        }
        var target = request.apkUrl
        var connection: HttpURLConnection? = null
        try {
            for (hop in 0..5) {
                check()
                if (!UpdateDownloadPolicy.allowedUrl(target, redirect = hop > 0)) {
                    throw AppOperationException("下载地址不受信任")
                }
                val active = open(URL(target))
                connection = active
                connectionChanged(active)
                active.connectTimeout = 15_000
                active.readTimeout = 25_000
                active.instanceFollowRedirects = false
                active.setRequestProperty("Accept", if (URL(target).host == "api.github.com")
                    "application/vnd.github.raw+json, application/octet-stream" else "application/octet-stream")
                active.setRequestProperty("Accept-Encoding", "identity")
                active.setRequestProperty("User-Agent", "fake-location-updater")
                val code = active.responseCode
                check()
                if (code in listOf(301, 302, 303, 307, 308)) {
                    val location = active.getHeaderField("Location")
                        ?: throw AppOperationException("下载地址无效")
                    if (hop == 5) throw AppOperationException("下载重定向过多")
                    target = URL(URL(target), location).toString()
                    active.disconnect()
                    continue
                }
                if (code != 200) throw AppOperationException("下载失败（$code）")
                val declared = active.contentLengthLong
                if (declared > UpdateDownloadPolicy.MAX_BYTES ||
                    (declared >= 0 && request.apkBytes >= 0 && declared != request.apkBytes)
                ) throw AppOperationException("安装包大小不符")
                val total = if (request.apkBytes > 0) request.apkBytes else declared
                progress(0, total)
                val digest = MessageDigest.getInstance("SHA-256")
                var received = 0L
                active.inputStream.use { input ->
                    FileOutputStream(output).use { file ->
                        val buffer = ByteArray(32 * 1024)
                        while (true) {
                            check()
                            val count = input.read(buffer)
                            if (count < 0) break
                            check()
                            received += count
                            if (received > UpdateDownloadPolicy.MAX_BYTES || (total >= 0 && received > total)) {
                                throw AppOperationException("安装包大小不符")
                            }
                            file.write(buffer, 0, count)
                            digest.update(buffer, 0, count)
                            progress(received, total)
                        }
                        file.fd.sync()
                    }
                }
                check()
                if (!UpdateDownloadPolicy.validLength(received, declared, request.apkBytes)) {
                    throw AppOperationException("下载不完整，请重试")
                }
                verifying()
                if (digest.digest().joinToString("") { "%02x".format(it.toInt() and 255) } != request.sha256) {
                    throw AppOperationException("安装包校验失败")
                }
                return
            }
        } catch (failure: Exception) {
            output.delete()
            throw failure
        } finally {
            connection?.disconnect()
            connectionChanged(null)
        }
    }
}
