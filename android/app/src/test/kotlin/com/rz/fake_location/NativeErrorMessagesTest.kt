package com.rz.fake_location

import org.junit.Assert.*
import org.junit.Test
import java.io.IOException
import java.net.SocketTimeoutException

/** 英文系统异常不可泄漏到用户提示，业务校验仍需要保留具体中文原因。 */
class NativeErrorMessagesTest {
    @Test fun platformEnglishIsReplacedWithChineseReason() {
        assertEquals(
            "推送定位失败：权限不足，请检查系统授权",
            NativeErrorMessages.describe("推送定位失败", SecurityException("Permission denied")),
        )
        assertEquals(
            "读取定位失败：参数不合法或定位源不可用",
            NativeErrorMessages.describe("读取定位失败", IllegalArgumentException("provider not found")),
        )
        assertEquals(
            "操作失败：系统未完成操作，请稍后重试",
            NativeErrorMessages.describe("操作失败", Exception("Unrecognized engine error")),
        )
    }

    @Test fun systemNetworkErrorsDoNotRevealRawMessages() {
        assertEquals(
            "下载失败：网络连接超时，请稍后重试",
            NativeErrorMessages.describe("下载失败", SocketTimeoutException("Read timed out")),
        )
        assertFalse(NativeErrorMessages.describe("下载失败", IOException("broken pipe")).contains("broken pipe"))
    }

    @Test fun knownChineseValidationAndInstallGuidanceAreKept() {
        assertEquals(
            "更新失败：更新包签名不一致，已阻止安装",
            NativeErrorMessages.describe("更新失败", AppOperationException("更新包签名不一致，已阻止安装")),
        )
        assertEquals(
            "安装失败：请先允许本应用安装未知来源应用，返回后重试",
            NativeErrorMessages.describe("安装失败", InstallPermissionException()),
        )
    }
}
