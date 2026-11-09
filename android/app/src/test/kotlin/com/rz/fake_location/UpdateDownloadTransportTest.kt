package com.rz.fake_location

import org.junit.Assert.*
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.File
import java.io.InputStream
import java.io.InterruptedIOException
import java.net.HttpURLConnection
import java.net.URL
import java.nio.file.Files
import java.security.MessageDigest

/** 用真实临时文件验证下载字节、重定向与取消，不依赖 Android 网络或服务器。 */
class UpdateDownloadTransportTest {
    private val source = "https://yuetongdai0-glitch.github.io/fake-location-releases/releases/android/latest.apk"
    private fun request(bytes: ByteArray, expected: Long = bytes.size.toLong()) = UpdateRequest(
        "com.rz.fake_location", "1.4.2", 16, source,
        MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it.toInt() and 255) }, 24, expected,
    )

    private class Connection(
        url: URL, val bytes: ByteArray, val declared: Long = bytes.size.toLong(),
        val code: Int = 200, val redirect: String? = null,
    ) : HttpURLConnection(url) {
        var disconnected = false
        var read = false
        override fun connect() {}
        override fun disconnect() { disconnected = true }
        override fun usingProxy() = false
        override fun getResponseCode() = code
        override fun getContentLengthLong() = declared
        override fun getHeaderField(name: String?) = if (name == "Location") redirect else null
        override fun getInputStream(): InputStream { read = true; return ByteArrayInputStream(bytes) }
    }

    private fun withFile(action: (File) -> Unit) {
        val directory = Files.createTempDirectory("update-transport").toFile()
        try { action(File(directory, "candidate.part")) } finally { directory.deleteRecursively() }
    }

    @Test fun emitsRealByteProgressAndVerifiesBeforeCompleting() = withFile { file ->
        val bytes = ByteArray(90_000) { (it % 127).toByte() }
        val connection = Connection(URL(source), bytes)
        val progress = mutableListOf<Pair<Long, Long>>()
        var verified = false
        UpdateDownloadTransport({ connection }).download(request(bytes), file, { false }, {}, { got, total -> progress.add(got to total) }, { verified = true })
        assertArrayEquals(bytes, file.readBytes())
        assertEquals(bytes.size.toLong() to bytes.size.toLong(), progress.last())
        assertTrue(verified)
        assertTrue(connection.disconnected)
        assertFalse(connection.instanceFollowRedirects)
        assertEquals("identity", connection.getRequestProperty("Accept-Encoding"))
    }

    @Test fun followsTrustedCdnButRejectsUntrustedRedirectBeforeOpeningIt() = withFile { file ->
        val bytes = "APK fixture".toByteArray()
        val opened = mutableListOf<String>()
        val cdn = "https://release-assets.githubusercontent.com/release/file.apk"
        UpdateDownloadTransport({ url ->
            opened.add(url.toString())
            if (opened.size == 1) Connection(url, byteArrayOf(), code = 302, redirect = cdn) else Connection(url, bytes)
        }).download(request(bytes), file, { false }, {}, { _, _ -> }, {})
        assertEquals(listOf(source, cdn), opened)
        opened.clear()
        assertThrows(AppOperationException::class.java) {
            UpdateDownloadTransport({ url ->
                opened.add(url.toString())
                Connection(url, byteArrayOf(), code = 302, redirect = "https://evil.test/file.apk")
            }).download(request(bytes), file, { false }, {}, { _, _ -> }, {})
        }
        assertEquals(listOf(source), opened)
        assertFalse(file.exists())
    }

    @Test fun rejectsTruncatedBodyAndMismatchedManifestBeforeReading() = withFile { file ->
        val bytes = "APK fixture".toByteArray()
        val truncated = Connection(URL(source), bytes.copyOf(3), declared = bytes.size.toLong())
        assertThrows(AppOperationException::class.java) {
            UpdateDownloadTransport({ truncated }).download(request(bytes), file, { false }, {}, { _, _ -> }, {})
        }
        assertFalse(file.exists())
        val mismatch = Connection(URL(source), bytes, declared = 999L)
        assertThrows(AppOperationException::class.java) {
            UpdateDownloadTransport({ mismatch }).download(request(bytes), file, { false }, {}, { _, _ -> }, {})
        }
        assertFalse(mismatch.read)
    }

    @Test fun cancellationDeletesPartialAndCannotReachVerification() = withFile { file ->
        val bytes = ByteArray(90_000)
        var cancelled = false
        var verified = false
        val connection = Connection(URL(source), bytes)
        assertThrows(InterruptedIOException::class.java) {
            UpdateDownloadTransport({ connection }).download(request(bytes), file, { cancelled }, {}, { got, _ -> if (got > 0) cancelled = true }, { verified = true })
        }
        assertFalse(file.exists())
        assertFalse(verified)
        assertTrue(connection.disconnected)
    }

    @Test fun rejectsWrongDigestHttpErrorAndExcessiveRedirects() = withFile { file ->
        val bytes = "APK fixture".toByteArray()
        val bad = request(bytes).copy(sha256 = "0".repeat(64))
        assertThrows(AppOperationException::class.java) {
            UpdateDownloadTransport({ Connection(it, bytes) }).download(bad, file, { false }, {}, { _, _ -> }, {})
        }
        assertFalse(file.exists())
        assertThrows(AppOperationException::class.java) {
            UpdateDownloadTransport({ Connection(it, bytes, code = 503) }).download(request(bytes), file, { false }, {}, { _, _ -> }, {})
        }
        var connections = 0
        assertThrows(AppOperationException::class.java) {
            UpdateDownloadTransport({ connections++; Connection(it, byteArrayOf(), code = 302, redirect = source) }).download(request(bytes), file, { false }, {}, { _, _ -> }, {})
        }
        assertEquals(6, connections)
    }

    @Test fun unknownLengthStillReportsBytesAndGlobalDeadlineIsBounded() = withFile { file ->
        val bytes = "APK fixture".toByteArray()
        val progress = mutableListOf<Pair<Long, Long>>()
        UpdateDownloadTransport({ Connection(it, bytes, declared = -1) }).download(request(bytes, -1), file, { false }, {}, { got, total -> progress.add(got to total) }, {})
        assertEquals(bytes.size.toLong() to -1L, progress.last())
        var time = 0L
        assertThrows(AppOperationException::class.java) {
            UpdateDownloadTransport({ Connection(it, bytes) }, { time.also { time += 600_001 } }).download(request(bytes), file, { false }, {}, { _, _ -> }, {})
        }
        assertFalse(file.exists())
    }

    @Test fun apiRequestsRawBytesAndRejectsJsonInsteadOfInstallingIt() = withFile { file ->
        val bytes = "APK fixture".toByteArray()
        val api = "https://api.github.com/repos/yuetongdai0-glitch/fake-location-releases/contents/releases/android/latest.apk?ref=main"
        val connection = Connection(URL(api), bytes)
        UpdateDownloadTransport({ connection }).download(request(bytes).copy(apkUrl = api), file, { false }, {}, { _, _ -> }, {})
        assertEquals("application/vnd.github.raw+json, application/octet-stream", connection.getRequestProperty("Accept"))
        val json = "{\"encoding\":\"none\",\"content\":\"\"}".toByteArray()
        assertThrows(AppOperationException::class.java) {
            UpdateDownloadTransport({ Connection(it, json) }).download(request(bytes).copy(apkUrl = api), file, { false }, {}, { _, _ -> }, {})
        }
        assertFalse(file.exists())
    }
}
