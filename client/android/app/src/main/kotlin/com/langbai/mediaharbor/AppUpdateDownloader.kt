package com.langbai.mediaharbor

import android.content.Context
import java.io.File
import java.io.FileOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import java.util.Locale
import java.util.concurrent.ConcurrentHashMap

internal class AppUpdateDownloader(private val context: Context) {
    private val activeConnections = ConcurrentHashMap<String, HttpURLConnection>()
    private val cancelled = ConcurrentHashMap.newKeySet<String>()

    data class Progress(
        val downloadedBytes: Long,
        val totalBytes: Long?,
        val speedBytesPerSecond: Double?,
        val averageSpeedBytesPerSecond: Double?,
    )

    fun cancel(processId: String): Boolean {
        if (processId.isBlank()) return false
        val requested = cancelled.add(processId)
        val disconnected = activeConnections.remove(processId)?.let {
            it.disconnect()
            true
        } ?: false
        return requested || disconnected
    }

    fun cancelAll() {
        activeConnections.keys.toList().forEach(::cancel)
    }

    fun downloadAndVerify(
        processId: String,
        sourceUrl: String,
        expectedSha256: String,
        expectedSize: Long?,
        onProgress: (Progress) -> Unit,
    ): File {
        require(processId.isNotBlank()) { "更新任务编号不能为空" }
        val checksum = expectedSha256.lowercase(Locale.ROOT)
        require(checksum.matches(Regex("[0-9a-f]{64}"))) { "更新包 SHA-256 不正确" }
        require(expectedSize == null || expectedSize in 1..MAX_APK_BYTES) { "更新包大小不正确" }
        cancelled.remove(processId)
        val safeProcessId = processId.replace(Regex("[^A-Za-z0-9_-]"), "_").take(64)
            .ifEmpty { "app-update" }
        val updateDirectory = File(context.externalCacheDir ?: context.cacheDir, "app-updates")
        updateDirectory.mkdirs()
        updateDirectory.listFiles()?.filter { it.isFile && System.currentTimeMillis() - it.lastModified() > DAY_MS }
            ?.forEach(File::delete)
        val temporary = File(updateDirectory, "$safeProcessId.apk.part")
        val verified = File(updateDirectory, "$safeProcessId.apk")
        temporary.delete()
        verified.delete()
        var connection: HttpURLConnection? = null
        try {
            connection = openHttpsFollowingRedirects(sourceUrl)
            check(activeConnections.putIfAbsent(processId, connection) == null) {
                "同一更新任务已在运行"
            }
            val contentSize = connection.contentLengthLong.takeIf { it > 0 }
            require(contentSize == null || contentSize <= MAX_APK_BYTES) { "更新包超过 1 GB 安全上限" }
            if (expectedSize != null && contentSize != null) {
                require(contentSize == expectedSize) { "更新包大小与清单不一致" }
            }
            val total = expectedSize ?: contentSize
            val digest = MessageDigest.getInstance("SHA-256")
            val startedAt = System.nanoTime()
            var lastAt = startedAt
            var lastBytes = 0L
            var downloaded = 0L
            connection.inputStream.use { input ->
                FileOutputStream(temporary).use { output ->
                    val buffer = ByteArray(128 * 1024)
                    while (true) {
                        check(processId !in cancelled) { "更新下载已取消" }
                        val count = input.read(buffer)
                        if (count < 0) break
                        output.write(buffer, 0, count)
                        digest.update(buffer, 0, count)
                        downloaded += count
                        require(downloaded <= MAX_APK_BYTES) { "更新包超过 1 GB 安全上限" }
                        val now = System.nanoTime()
                        if (now - lastAt >= 250_000_000L || downloaded == total) {
                            val sample = (now - lastAt) / 1_000_000_000.0
                            val elapsed = (now - startedAt) / 1_000_000_000.0
                            onProgress(
                                Progress(
                                    downloaded,
                                    total,
                                    if (sample > 0) (downloaded - lastBytes) / sample else null,
                                    if (elapsed > 0) downloaded / elapsed else null,
                                ),
                            )
                            lastAt = now
                            lastBytes = downloaded
                        }
                    }
                }
            }
            require(expectedSize == null || downloaded == expectedSize) { "更新包下载不完整" }
            val actual = digest.digest().joinToString("") { "%02x".format(it.toInt() and 0xff) }
            require(actual == checksum) { "更新包 SHA-256 校验失败" }
            require(temporary.renameTo(verified)) { "无法保存已校验的更新包" }
            return verified
        } catch (failure: Throwable) {
            temporary.delete()
            verified.delete()
            if (processId in cancelled) throw IllegalStateException("更新下载已取消")
            throw failure
        } finally {
            connection?.let { activeConnections.remove(processId, it) }
            connection?.disconnect()
            cancelled.remove(processId)
        }
    }

    private fun openHttpsFollowingRedirects(initialUrl: String): HttpURLConnection {
        var current = URL(initialUrl)
        repeat(6) {
            require(current.protocol.equals("https", ignoreCase = true)) { "更新包必须使用 HTTPS 下载" }
            require(current.userInfo.isNullOrEmpty()) { "更新下载地址不能包含账号信息" }
            val connection = current.openConnection() as HttpURLConnection
            connection.instanceFollowRedirects = false
            connection.connectTimeout = 20_000
            connection.readTimeout = 45_000
            connection.setRequestProperty("User-Agent", "langbai-resolver-android-updater")
            connection.setRequestProperty("Accept", "application/vnd.android.package-archive,application/octet-stream")
            connection.connect()
            val status = connection.responseCode
            if (status in 300..399) {
                val location = connection.getHeaderField("Location")
                connection.disconnect()
                require(!location.isNullOrBlank()) { "更新下载跳转地址无效" }
                current = URL(current, location)
                return@repeat
            }
            require(status in 200..299) { "更新服务器返回 $status" }
            return connection
        }
        error("更新下载跳转次数过多")
    }

    companion object {
        private const val MAX_APK_BYTES = 1024L * 1024 * 1024
        private const val DAY_MS = 24L * 60 * 60 * 1000
    }
}
