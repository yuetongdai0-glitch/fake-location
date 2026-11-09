package com.rz.fake_location

import org.junit.Assert.*
import org.junit.Test

/** 限定本项目发行文件，防止清单、重定向和长度字段扩大信任范围。 */
class UpdateDownloadPolicyTest {
    private val base = "https://yuetongdai0-glitch.github.io/fake-location-releases/releases/android/latest.apk"

    @Test fun acceptsOnlyOwnedReleasePathsAtInitialHop() {
        assertTrue(UpdateDownloadPolicy.allowedUrl("$base?v=16"))
        assertTrue(UpdateDownloadPolicy.allowedUrl("https://raw.githubusercontent.com/yuetongdai0-glitch/fake-location-releases/main/releases/android/latest.apk"))
        assertTrue(UpdateDownloadPolicy.allowedUrl("https://github.com/yuetongdai0-glitch/fake-location-releases/releases/download/v1.4.2/app.apk"))
        for (url in listOf(
            base.replace("yuetongdai0-glitch", "another-owner"),
            base.replace("latest.apk", "other.apk"),
            "https://raw.githubusercontent.com/another-owner/fake-location-releases/main/releases/android/latest.apk",
            "https://github.com/yuetongdai0-glitch/another-repo/releases/download/v1/app.apk",
            "https://release-assets.githubusercontent.com/package.apk",
        )) assertFalse(url, UpdateDownloadPolicy.allowedUrl(url))
    }

    @Test fun rejectsHttpCredentialsPortsFragmentsAndEncodedTraversal() {
        for (url in listOf(
            base.replace("https:", "http:"),
            base.replace("https://", "https://user:secret@"),
            base.replace(".io/", ".io:8443/"),
            "$base#fragment",
            base.replace("releases/android/", "releases/../android/"),
            base.replace("releases/android/", "releases/%2e%2e/android/"),
            base.replace("releases/android/", "releases%2fandroid/"),
        )) assertFalse(url, UpdateDownloadPolicy.allowedUrl(url))
    }

    @Test fun cdnIsAllowedOnlyAfterTrustedInitialHop() {
        val cdn = "https://release-assets.githubusercontent.com/github-production-release-asset/sample?token=public-signature"
        assertFalse(UpdateDownloadPolicy.allowedUrl(cdn))
        assertTrue(UpdateDownloadPolicy.allowedUrl(cdn, redirect = true))
        assertFalse(UpdateDownloadPolicy.allowedUrl("https://release-assets.githubusercontent.com.evil.test/file.apk", true))
        assertFalse(UpdateDownloadPolicy.allowedUrl("http://objects.githubusercontent.com/file.apk", true))
    }

    @Test fun alternateSourcesStayInSameReleaseRepository() {
        val sources = UpdateDownloadPolicy.downloadSources("$base?v=16", 16)
        assertEquals(3, sources.size)
        assertTrue(sources.all { UpdateDownloadPolicy.allowedUrl(it) })
        assertTrue(sources[1].startsWith("https://raw.githubusercontent.com/yuetongdai0-glitch/fake-location-releases/main/"))
        val rawFirst = UpdateDownloadPolicy.downloadSources(sources[1], 16)
        assertTrue(rawFirst[1].startsWith("https://yuetongdai0-glitch.github.io/fake-location-releases/"))
        assertEquals("https://api.github.com/repos/yuetongdai0-glitch/fake-location-releases/contents/releases/android/latest.apk?ref=main", sources[2])
    }

    @Test fun apiRawSourceRequiresExactPathAndMainRef() {
        val api = "https://api.github.com/repos/yuetongdai0-glitch/fake-location-releases/contents/releases/android/latest.apk"
        assertTrue(UpdateDownloadPolicy.allowedUrl("$api?ref=main"))
        assertTrue(UpdateDownloadPolicy.allowedUrl("$api?ref=main&_=123"))
        for (url in listOf(api, "$api?ref=other", "$api?ref=main&ref=other", "$api?ref=main&ref=main", "$api?ref=main&_=1&_=2", "$api?ref=main&token=unrelated", api.replace("latest.apk", "other.apk") + "?ref=main")) {
            assertFalse(url, UpdateDownloadPolicy.allowedUrl(url))
        }
    }

    @Test fun checksBothManifestAndServerLengthsAndHardLimit() {
        assertTrue(UpdateDownloadPolicy.validLength(100, 100, 100))
        assertTrue(UpdateDownloadPolicy.validLength(100, -1, -1))
        assertFalse(UpdateDownloadPolicy.validLength(0, -1, -1))
        assertFalse(UpdateDownloadPolicy.validLength(100, 99, 100))
        assertFalse(UpdateDownloadPolicy.validLength(100, 100, 101))
        assertFalse(UpdateDownloadPolicy.validLength(UpdateDownloadPolicy.MAX_BYTES + 1, -1, -1))
    }

    @Test fun rejectsDowngradeWrongPackageMalformedNumbersAndUnsupportedSdk() {
        val request = UpdateRequest("com.rz.fake_location", "1.4.2", 16, base, "a".repeat(64), 24, 100)
        assertEquals(request, UpdateRequest.parse(request.fields(), request.packageId, 15, 36))
        for (change in listOf(
            "packageId" to "other.package", "versionCode" to 15,
            "versionCode" to Double.NaN, "apkBytes" to false,
            "apkBytes" to 0L, "minSdk" to 37, "minSdk" to 0,
            "sha256" to "abcd", "versionName" to "",
        )) {
            val fields = request.fields().toMutableMap().apply { put(change.first, change.second) }
            assertThrows(AppOperationException::class.java) { UpdateRequest.parse(fields, request.packageId, 15, 36) }
        }
    }
}
