package com.rz.fake_location

import java.io.IOException
import java.net.SocketTimeoutException
import java.net.UnknownHostException
import javax.net.ssl.SSLException

/** 仅业务校验可以携带预先编写的中文提示，系统异常原文不能直接穿过平台通道。 */
internal class AppOperationException(val userMessage: String) : IOException(userMessage)

/** 安装授权保留独立类型，以便界面按 INSTALL_PERMISSION 错误码引导用户。 */
internal class InstallPermissionException : SecurityException()

/** 将平台错误转换为中文原因类别，避免系统/第三方英文异常直接显示给用户。 */
internal object NativeErrorMessages {
    fun describe(action: String, failure: Exception): String {
        val reason = when (failure) {
            is AppOperationException -> failure.userMessage
            is InstallPermissionException -> "请先允许本应用安装未知来源应用，返回后重试"
            is SecurityException -> "权限不足，请检查系统授权"
            is SocketTimeoutException -> "网络连接超时，请稍后重试"
            is UnknownHostException -> "无法连接服务器，请检查网络"
            is SSLException -> "安全连接失败，请检查网络或系统时间"
            is IOException -> "网络连接或文件读取失败，请稍后重试"
            is IllegalArgumentException -> "参数不合法或定位源不可用"
            is IllegalStateException -> "系统状态暂不可用，请稍后重试"
            is UnsupportedOperationException -> "系统暂不支持此功能"
            else -> "系统未完成操作，请稍后重试"
        }
        return "$action：$reason"
    }
}
