package com.rz.fake_location

import android.app.Activity
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings
import androidx.core.content.FileProvider
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.io.InterruptedIOException
import java.net.HttpURLConnection
import java.security.MessageDigest
import java.util.concurrent.Executors

/** 独立维护更新任务：进度、取消、缓存和系统安装授权不再挤在一次阻塞调用里。 */
internal class AppUpdateController(
    private val activity: Activity,
    private val notifyStatus: (Map<String, Any?>) -> Unit,
) {
    companion object { const val INSTALL_REQUEST = 62041 }

    private val executor = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private val directory = File(activity.cacheDir, "updates").apply { mkdirs() }
    private val metadata = File(directory, "ready.json")
    @Volatile private var generation = 0
    @Volatile private var connection: HttpURLConnection? = null
    private var state = "idle"
    private var error = ""
    private var request: UpdateRequest? = null
    private var readyFile: File? = null
    private var received = 0L
    private var total = -1L
    private var waitingPermission = false
    private var lastNotificationAt = 0L
    private var revision = 0L

    init { executor.execute(::restoreReady) }

    /** 状态可重复查询；旧面板关闭重开时不重新下载，也不丢失失败原因。 */
    @Synchronized fun status(): Map<String, Any?> {
        if (state in setOf("ready", "permission", "error") && readyFile != null && readyFile?.isFile != true) {
            invalidateCache()
        }
        return mapOf(
            "state" to state, "error" to error, "operationId" to generation, "revision" to revision,
            "receivedBytes" to received, "totalBytes" to total,
            "progress" to if (state == "ready" || state == "permission" || state == "installing") 100
                else if (total > 0) ((received * 100 / total).coerceIn(0, 99)).toInt() else -1,
            "versionName" to request?.versionName, "versionCode" to request?.versionCode,
            "canInstall" to (readyFile?.isFile == true && state in setOf("ready", "permission", "installing", "error")),
        )
    }

    /** 下载立即返回当前快照，后台任务只接收已经验证的同包升版参数。 */
    @Synchronized fun download(raw: Map<*, *>): Map<String, Any?> {
        if (state in setOf("downloading", "verifying", "installing")) throw AppOperationException("更新正在进行")
        val target = UpdateRequest.parse(raw, activity.packageName, version(installed()), Build.VERSION.SDK_INT)
        val job = ++generation
        request = target
        readyFile = null
        waitingPermission = false
        error = ""
        state = "downloading"
        received = 0
        total = target.apkBytes
        emit()
        executor.execute { download(job, target) }
        return status()
    }

    /** 取消会废弃任务代次并主动断连，迟到下载或校验不能重新变成可安装。 */
    @Synchronized fun cancel(): Map<String, Any?> {
        if (state == "installing") return status()
        generation++
        connection?.disconnect()
        connection = null
        clearPermissionResume()
        waitingPermission = false
        readyFile = null
        state = "cancelled"
        error = ""
        emit()
        return status()
    }

    /** 只安装已校验缓存；返回授权页后仍用同一文件，不再次下载几十兆安装包。 */
    @Synchronized fun install(): Map<String, Any?> {
        if (state == "installing" || state == "verifying") return status()
        val target = request ?: throw AppOperationException("请先下载更新")
        val apk = readyFile?.takeIf { it.isFile }
        if (apk == null) {
            invalidateCache()
            emit()
            throw AppOperationException("安装包已失效，请重新下载")
        }
        val job = generation
        state = "verifying"
        error = ""
        emit()
        executor.execute {
            try {
                verifyFile(apk, target) { job != generation }
                main.post {
                    if (job != generation) return@post
                    try { launchInstaller(apk, target) }
                    catch (failure: Exception) { fail(job, failure) }
                }
            } catch (failure: Exception) {
                if (failure !is InterruptedIOException) {
                    apk.delete()
                    metadata.delete()
                    synchronized(this) { if (job == generation) readyFile = null }
                }
                fail(job, failure)
            }
        }
        return status()
    }

    /** 系统设置返回后只续接用户刚才的安装动作，不自动授予未知来源权限。 */
    @Synchronized fun onResume() {
        if (!waitingPermission) return
        waitingPermission = false
        clearPermissionResume()
        if (canInstallPackages()) install() else {
            state = "permission"
            error = "请允许安装此应用"
            emit()
        }
    }

    /** 用户取消系统安装后保留通过校验的文件，允许直接再次安装。 */
    @Synchronized fun onInstallResult(resultCode: Int) {
        if (state != "installing") return
        state = "ready"
        error = if (resultCode == Activity.RESULT_OK) "" else "安装未完成，可重试"
        emit()
    }

    /** Activity 销毁后旧任务不可继续发布事件，已验证缓存保留供下次恢复。 */
    @Synchronized fun close() {
        generation++
        connection?.disconnect()
        executor.shutdownNow()
    }

    private fun download(job: Int, target: UpdateRequest) {
        val apk = File(directory, "${target.versionCode}-${target.sha256}.apk")
        val part = File(directory, "download-$job.part")
        try {
            if (apk.isFile) {
                try {
                    change(job, "verifying", apk.length(), apk.length())
                    verifyFile(apk, target) { job != generation }
                    ready(job, target, apk)
                    return
                } catch (failure: Exception) {
                    if (job != generation) throw failure
                    apk.delete()
                }
            }
            val needed = if (target.apkBytes > 0) target.apkBytes else 64L * 1024 * 1024
            if (directory.usableSpace < needed + 8L * 1024 * 1024) throw AppOperationException("存储空间不足")
            // 全任务共用十分钟预算；固定同仓库备用入口可避开 Pages 旧缓存，不引入镜像站。
            val deadline = SystemClock.elapsedRealtime() + 10 * 60_000L
            var downloaded = false
            var lastFailure: Exception? = null
            for (source in UpdateDownloadPolicy.downloadSources(target.apkUrl, target.versionCode)) {
                try {
                    for (attempt in 0..1) {
                        try {
                            val budget = deadline - SystemClock.elapsedRealtime()
                            if (budget <= 0) throw AppOperationException("下载超时，请重试")
                            change(job, "downloading", 0, target.apkBytes)
                            UpdateDownloadTransport().download(
                                target.copy(apkUrl = source), part, { job != generation },
                                { connection = it },
                                { bytes, expected -> change(job, "downloading", bytes, expected, throttle = true) },
                                { change(job, "verifying", part.length(), part.length()) }, budget,
                            )
                            downloaded = true
                            break
                        } catch (failure: IOException) {
                            if (job != generation || attempt == 1 || failure is AppOperationException) throw failure
                        }
                    }
                    break
                } catch (failure: Exception) {
                    if (job != generation) throw failure
                    lastFailure = failure
                }
            }
            if (!downloaded) throw lastFailure ?: AppOperationException("下载失败，请重试")
            verifyApk(part, target)
            if (job != generation) throw InterruptedIOException()
            if (!part.renameTo(apk)) throw AppOperationException("安装包保存失败")
            ready(job, target, apk)
        } catch (failure: Exception) { fail(job, failure) }
        finally { part.delete() }
    }

    /** 只有本代次完成所有校验后才能存入可安装状态和缓存索引。 */
    @Synchronized private fun ready(job: Int, target: UpdateRequest, apk: File) {
        if (job != generation) return
        metadata.writeText(JSONObject(target.fields()).toString())
        request = target
        readyFile = apk
        state = "ready"
        received = apk.length()
        total = received
        error = ""
        emit()
    }

    private fun restoreReady() {
        if (!metadata.isFile) return
        var validating = false
        var cachedFile: File? = null
        try {
            val json = JSONObject(metadata.readText())
            val raw = json.keys().asSequence().associateWith { json.get(it) }
            val resumePermission = json.optBoolean("awaitingPermission", false)
            val target = UpdateRequest.parse(raw, activity.packageName, version(installed()), Build.VERSION.SDK_INT)
            val apk = File(directory, "${target.versionCode}-${target.sha256}.apk")
            if (!apk.isFile) return
            cachedFile = apk
            synchronized(this) {
                if (generation != 0) return
                request = target
                state = "verifying"
                validating = true
                emit()
            }
            verifyFile(apk, target) { generation != 0 }
            ready(0, target, apk)
            if (resumePermission) main.post {
                synchronized(this) {
                    if (generation != 0) return@post
                    if (canInstallPackages()) install() else {
                        state = "permission"
                        error = "请允许安装此应用"
                        emit()
                    }
                }
            }
        } catch (_: Exception) {
            synchronized(this) {
                if (generation == 0) {
                    metadata.delete()
                    cachedFile?.delete()
                    readyFile = null
                    // 已显示校验中的任务必须以明确失败收尾，不能回 idle 后让面板永久等待。
                    if (validating) {
                        state = "error"
                        error = "安装包已失效，请重新检查更新"
                    } else {
                        state = "idle"
                        request = null
                    }
                    emit()
                }
            }
        }
    }

    /** 每次调系统安装器之前再次核对缓存字节和包身份，缓存不是永久信任。 */
    private fun verifyFile(apk: File, target: UpdateRequest, cancelled: () -> Boolean) {
        val size = apk.length()
        if (!UpdateDownloadPolicy.validLength(size, -1, target.apkBytes)) throw AppOperationException("安装包已失效，请重新下载")
        val digest = MessageDigest.getInstance("SHA-256")
        apk.inputStream().use { input ->
            val bytes = ByteArray(32 * 1024)
            while (true) {
                if (cancelled()) throw InterruptedIOException()
                val count = input.read(bytes)
                if (count < 0) break
                digest.update(bytes, 0, count)
            }
        }
        if (hex(digest.digest()) != target.sha256) throw AppOperationException("安装包校验失败，请重新下载")
        verifyApk(apk, target)
    }

    private fun verifyApk(apk: File, target: UpdateRequest) {
        val flags = if (Build.VERSION.SDK_INT >= 28) PackageManager.GET_SIGNING_CERTIFICATES else {
            @Suppress("DEPRECATION")
            PackageManager.GET_SIGNATURES
        }
        val candidate = activity.packageManager.getPackageArchiveInfo(apk.absolutePath, flags)
            ?: throw AppOperationException("安装包无效")
        val current = activity.packageManager.getPackageInfo(activity.packageName, flags)
        if (candidate.packageName != target.packageId || version(candidate) != target.versionCode ||
            candidate.versionName != target.versionName || version(candidate) <= version(current)
        ) throw AppOperationException("安装包版本不符")
        if (candidate.applicationInfo == null || candidate.applicationInfo!!.minSdkVersion > Build.VERSION.SDK_INT) {
            throw AppOperationException("当前系统不支持此版本")
        }
        if (signatures(candidate) != signatures(current)) throw AppOperationException("安装包签名不符")
    }

    @Synchronized private fun launchInstaller(apk: File, target: UpdateRequest) {
        if (!canInstallPackages()) {
            state = "permission"
            waitingPermission = true
            // 厂商系统可能在设置页期间回收 Activity，重建后仍能继续原安装动作。
            metadata.writeText(JSONObject(target.fields()).put("awaitingPermission", true).toString())
            emit()
            activity.startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${activity.packageName}")))
            return
        }
        val uri = FileProvider.getUriForFile(activity, "${activity.packageName}.fileprovider", apk)
        val intent = Intent(Intent.ACTION_INSTALL_PACKAGE).setDataAndType(uri, "application/vnd.android.package-archive")
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION).putExtra(Intent.EXTRA_RETURN_RESULT, true)
        @Suppress("DEPRECATION")
        activity.startActivityForResult(intent, INSTALL_REQUEST)
        request = target
        state = "installing"
        emit()
    }

    /** 系统清理缓存后撤销可安装状态，不让查询或再次安装继续显示旧的“已就绪”。 */
    private fun invalidateCache() {
        readyFile = null
        waitingPermission = false
        metadata.delete()
        state = "error"
        error = "安装包已失效，请重新下载"
        revision++
    }

    /** 明确取消或已返回设置后撤销自动续装标记；写入失败就删索引，不能留下旧授权动作。 */
    private fun clearPermissionResume() {
        if (!metadata.isFile) return
        try {
            metadata.writeText(JSONObject(metadata.readText()).put("awaitingPermission", false).toString())
        } catch (_: Exception) { metadata.delete() }
    }

    @Synchronized private fun change(job: Int, next: String, bytes: Long, expected: Long, throttle: Boolean = false) {
        if (job != generation) return
        state = next
        received = bytes
        total = expected
        revision++
        val now = SystemClock.elapsedRealtime()
        if (!throttle || now - lastNotificationAt >= 200) { lastNotificationAt = now; emit() }
    }

    @Synchronized private fun fail(job: Int, failure: Exception) {
        if (job != generation) return
        state = "error"
        error = if (failure is AppOperationException) failure.userMessage
            else NativeErrorMessages.describe("更新失败", failure)
        emit()
    }

    /** 事件与查询共用同一快照，主线程派发保持变更顺序。 */
    private fun emit() {
        revision++
        val snapshot = status()
        main.post { if (snapshot["operationId"] == generation) notifyStatus(snapshot) }
    }

    private fun canInstallPackages() = Build.VERSION.SDK_INT < 26 || activity.packageManager.canRequestPackageInstalls()
    private fun installed(): PackageInfo = activity.packageManager.getPackageInfo(activity.packageName, 0)
    private fun version(info: PackageInfo): Long = if (Build.VERSION.SDK_INT >= 28) info.longVersionCode else {
        @Suppress("DEPRECATION")
        info.versionCode.toLong()
    }

    private fun signatures(info: PackageInfo): Set<String> {
        val signatures = if (Build.VERSION.SDK_INT >= 28) info.signingInfo?.apkContentsSigners else {
            @Suppress("DEPRECATION")
            info.signatures
        }
        if (signatures.isNullOrEmpty()) throw AppOperationException("无法读取安装包签名")
        return signatures.mapTo(mutableSetOf()) { hex(MessageDigest.getInstance("SHA-256").digest(it.toByteArray())) }
    }

    private fun hex(bytes: ByteArray): String = bytes.joinToString("") { "%02x".format(it.toInt() and 255) }
}
