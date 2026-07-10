package com.langbai.mediaharbor

import android.content.ContentValues
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import com.yausername.aria2c.Aria2c
import com.yausername.ffmpeg.FFmpeg
import com.yausername.youtubedl_android.YoutubeDL
import com.yausername.youtubedl_android.YoutubeDLRequest
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val worker = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())
    private val resolved = ConcurrentHashMap<String, LocalMedia>()
    private lateinit var channel: MethodChannel

    @Volatile
    private var engineReady = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.langbai.resolver/local_media",
        )
        channel.setMethodCallHandler(::handleMethodCall)
    }

    override fun onDestroy() {
        worker.shutdownNow()
        super.onDestroy()
    }

    private fun handleMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "isAvailable" -> result.success(true)
            "resolve" -> runAsync(result) {
                val url = call.argument<String>("url")?.trim().orEmpty()
                require(url.startsWith("https://") || url.startsWith("http://")) {
                    "请输入完整的 http 或 https 链接"
                }
                resolveLocally(url)
            }
            "download" -> runAsync(result) {
                val mediaId = call.argument<String>("media_id").orEmpty()
                val optionId = call.argument<String>("option_id").orEmpty()
                val processId = call.argument<String>("process_id") ?: UUID.randomUUID().toString()
                downloadLocally(mediaId, optionId, processId)
            }
            "updateEngine" -> runAsync(result) {
                ensureEngine()
                YoutubeDL.getInstance().updateYoutubeDL(
                    applicationContext,
                    YoutubeDL.UpdateChannel.STABLE,
                )
                mapOf(
                    "version" to (YoutubeDL.getInstance().versionName(applicationContext) ?: "最新版本"),
                )
            }
            else -> result.notImplemented()
        }
    }

    private fun runAsync(
        result: MethodChannel.Result,
        action: () -> Any?,
    ) {
        worker.execute {
            try {
                val value = action()
                mainHandler.post { result.success(value) }
            } catch (error: Throwable) {
                val message = friendlyMessage(error)
                mainHandler.post { result.error("LOCAL_MEDIA_ERROR", message, null) }
            }
        }
    }

    @Synchronized
    private fun ensureEngine() {
        if (engineReady) return
        YoutubeDL.getInstance().init(applicationContext)
        FFmpeg.getInstance().init(applicationContext)
        Aria2c.getInstance().init(applicationContext)
        engineReady = true
    }

    private fun resolveLocally(url: String): Map<String, Any?> {
        ensureEngine()
        val request = YoutubeDLRequest(url)
            .addOption("--dump-single-json")
            .addOption("--no-playlist")
            .addOption("--skip-download")
            .addOption("--socket-timeout", "25")
            .addOption("--retries", "2")
        val response = YoutubeDL.getInstance().execute(request)
        val root = JSONObject(response.out.trim())
        val effective = effectiveEntry(root)
        val mediaId = UUID.randomUUID().toString()
        val specs = linkedMapOf<String, LocalOption>()
        val options = mutableListOf<Map<String, Any?>>()

        addVideoOptions(effective.optJSONArray("formats"), specs, options)
        addAudioOptions(effective.optJSONArray("formats"), specs, options)
        addEntryImages(root.optJSONArray("entries"), specs, options)

        val thumbnail = text(effective, "thumbnail") ?: text(root, "thumbnail")
        if (!thumbnail.isNullOrBlank()) {
            val extension = extensionFromUrl(thumbnail, "jpg")
            val id = "image:cover"
            specs[id] = LocalOption(
                kind = "image",
                extension = extension,
                directUrl = thumbnail,
            )
            options += optionMap(
                id = id,
                kind = "image",
                label = "最高质量封面 · ${extension.uppercase()}",
                extension = extension,
            )
        }

        if (options.isEmpty()) {
            addDirectMediaOption(url, effective, specs, options)
        }
        require(options.isNotEmpty()) { "该页面暂未发现可下载的公开媒体" }

        val sourceUrl = text(effective, "webpage_url")
            ?: text(root, "webpage_url")
            ?: url
        val title = text(effective, "title") ?: text(root, "title") ?: "未命名媒体"
        resolved[mediaId] = LocalMedia(sourceUrl, title, specs)
        if (resolved.size > 80) resolved.keys.firstOrNull()?.let(resolved::remove)

        return mapOf(
            "media_id" to mediaId,
            "source_url" to sourceUrl,
            "title" to title,
            "creator" to (
                text(effective, "uploader")
                    ?: text(effective, "creator")
                    ?: text(effective, "channel")
                ),
            "platform" to (
                text(effective, "extractor_key")
                    ?: text(effective, "extractor")
                    ?: "本地通用解析"
                ),
            "duration_seconds" to positiveInt(effective, "duration"),
            "thumbnail_url" to thumbnail,
            "options" to options,
            "warnings" to listOf("由 Android 本机解析，媒体链接和 Cookie 不会发送到 langbai 服务器。"),
        )
    }

    private fun effectiveEntry(root: JSONObject): JSONObject {
        if (root.optJSONArray("formats")?.length() ?: 0 > 0) return root
        val entries = root.optJSONArray("entries") ?: return root
        for (index in 0 until entries.length()) {
            val item = entries.optJSONObject(index) ?: continue
            if ((item.optJSONArray("formats")?.length() ?: 0) > 0) return item
        }
        return root
    }

    private fun addVideoOptions(
        formats: JSONArray?,
        specs: MutableMap<String, LocalOption>,
        options: MutableList<Map<String, Any?>>,
    ) {
        if (formats == null) return
        val candidates = mutableListOf<JSONObject>()
        for (index in 0 until formats.length()) {
            val item = formats.optJSONObject(index) ?: continue
            val formatId = text(item, "format_id") ?: continue
            val videoCodec = text(item, "vcodec")
            if (videoCodec.isNullOrBlank() || videoCodec == "none") continue
            if (formatId.isBlank()) continue
            candidates += item
        }
        val seen = mutableSetOf<String>()
        candidates.sortedWith(
            compareByDescending<JSONObject> { it.optInt("height", 0) }
                .thenByDescending { it.optDouble("fps", 0.0) }
                .thenByDescending { it.optDouble("tbr", 0.0) },
        ).take(60).forEach { item ->
            val formatId = text(item, "format_id") ?: return@forEach
            val height = item.optInt("height", 0).takeIf { it > 0 }
            val width = item.optInt("width", 0).takeIf { it > 0 }
            val fps = item.optDouble("fps", 0.0).takeIf { it > 0 }
            val extension = text(item, "ext")?.lowercase() ?: "mp4"
            val hasAudio = text(item, "acodec").let { !it.isNullOrBlank() && it != "none" }
            val key = "$width:$height:${fps?.toInt()}:$extension:$hasAudio"
            if (!seen.add(key) || options.count { it["kind"] == "video" } >= 30) return@forEach
            val id = "video:$formatId"
            val selector = if (hasAudio) {
                formatId
            } else if (extension in setOf("mp4", "m4v", "mov")) {
                "$formatId+bestaudio[ext=m4a]/$formatId+bestaudio/$formatId"
            } else {
                "$formatId+bestaudio/$formatId"
            }
            specs[id] = LocalOption(
                kind = "video",
                extension = extension,
                selector = selector,
            )
            val label = buildList {
                add(height?.let { "${it}p" } ?: text(item, "format_note") ?: "视频")
                if (fps != null && fps > 30) add("${fps.toInt()}fps")
                add(extension.uppercase())
                add(if (hasAudio) "音画合一" else "自动合并音频")
            }.joinToString(" · ")
            val size = positiveLong(item, "filesize") ?: positiveLong(item, "filesize_approx")
            options += optionMap(
                id = id,
                kind = "video",
                label = label,
                extension = extension,
                resolution = if (width != null && height != null) "${width}×${height}" else height?.let { "${it}p" },
                fps = fps,
                filesize = size,
                requiresMerge = !hasAudio,
            )
        }
    }

    private fun addAudioOptions(
        formats: JSONArray?,
        specs: MutableMap<String, LocalOption>,
        options: MutableList<Map<String, Any?>>,
    ) {
        if (formats == null) return
        var hasAudio = false
        for (index in 0 until formats.length()) {
            val codec = text(formats.optJSONObject(index) ?: continue, "acodec")
            if (!codec.isNullOrBlank() && codec != "none") {
                hasAudio = true
                break
            }
        }
        if (!hasAudio) return
        val presets = listOf(
            AudioPreset("audio:m4a:256", "M4A · 256 kbps", "m4a", "256K"),
            AudioPreset("audio:mp3:320", "MP3 · 320 kbps", "mp3", "320K"),
            AudioPreset("audio:mp3:192", "MP3 · 192 kbps", "mp3", "192K"),
        )
        presets.forEach { preset ->
            specs[preset.id] = LocalOption(
                kind = "audio",
                extension = preset.extension,
                selector = "bestaudio/best",
                audioQuality = preset.quality,
            )
            options += optionMap(
                id = preset.id,
                kind = "audio",
                label = preset.label,
                extension = preset.extension,
                bitrate = preset.quality.removeSuffix("K").toIntOrNull(),
            )
        }
    }

    private fun addEntryImages(
        entries: JSONArray?,
        specs: MutableMap<String, LocalOption>,
        options: MutableList<Map<String, Any?>>,
    ) {
        if (entries == null) return
        var imageIndex = 0
        for (index in 0 until entries.length()) {
            val item = entries.optJSONObject(index) ?: continue
            val direct = text(item, "url") ?: continue
            val extension = (text(item, "ext") ?: extensionFromUrl(direct, "")).lowercase()
            if (extension !in IMAGE_EXTENSIONS) continue
            imageIndex += 1
            val id = "image:entry:$imageIndex"
            specs[id] = LocalOption("image", extension, directUrl = direct)
            options += optionMap(
                id = id,
                kind = "image",
                label = "图集图片 $imageIndex · ${extension.uppercase()}",
                extension = extension,
            )
            if (imageIndex >= 40) break
        }
    }

    private fun addDirectMediaOption(
        sourceUrl: String,
        info: JSONObject,
        specs: MutableMap<String, LocalOption>,
        options: MutableList<Map<String, Any?>>,
    ) {
        val direct = text(info, "url") ?: sourceUrl
        val extension = (text(info, "ext") ?: extensionFromUrl(direct, "mp4")).lowercase()
        val kind = when (extension) {
            in IMAGE_EXTENSIONS -> "image"
            in AUDIO_EXTENSIONS -> "audio"
            else -> "video"
        }
        val id = "$kind:direct"
        specs[id] = LocalOption(kind, extension, directUrl = direct)
        options += optionMap(
            id = id,
            kind = kind,
            label = "原始${kindLabel(kind)} · ${extension.uppercase()}",
            extension = extension,
        )
    }

    private fun downloadLocally(
        mediaId: String,
        optionId: String,
        processId: String,
    ): Map<String, Any?> {
        ensureEngine()
        val media = resolved[mediaId] ?: error("解析结果已过期，请重新解析链接")
        val option = media.options[optionId] ?: error("所选格式不存在，请重新解析")
        val taskDir = File(cacheDir, "local-media/$processId")
        taskDir.deleteRecursively()
        taskDir.mkdirs()
        val output = if (option.directUrl != null) {
            downloadDirect(option.directUrl, media.title, option.extension, taskDir, processId)
        } else {
            downloadWithYtDlp(media, option, taskDir, processId)
        }
        val published = publishToDownloads(output)
        taskDir.deleteRecursively()
        return mapOf(
            "filename" to published.name,
            "path" to published.location,
            "message" to "已保存到 Download/langbai解析/${published.name}",
        )
    }

    private fun downloadWithYtDlp(
        media: LocalMedia,
        option: LocalOption,
        taskDir: File,
        processId: String,
    ): File {
        val template = File(taskDir, "%(title).160B [%(id)s].%(ext)s").absolutePath
        val request = YoutubeDLRequest(media.sourceUrl)
            .addOption("--no-playlist")
            .addOption("--no-mtime")
            .addOption("--newline")
            .addOption("--concurrent-fragments", "4")
            .addOption("--retries", "4")
            .addOption("-o", template)
        option.selector?.let { request.addOption("-f", it) }
        if (option.kind == "audio") {
            request
                .addOption("--extract-audio")
                .addOption("--audio-format", option.extension)
                .addOption("--audio-quality", option.audioQuality ?: "0")
        }
        YoutubeDL.getInstance().execute(request, processId) { progress, eta, line ->
            emitProgress(processId, progress.toDouble(), eta, line)
        }
        return taskDir.walkTopDown()
            .filter { it.isFile && !it.name.endsWith(".part") && !it.name.endsWith(".ytdl") }
            .maxByOrNull { it.length() }
            ?: error("下载完成但没有找到输出文件")
    }

    private fun downloadDirect(
        directUrl: String,
        title: String,
        extension: String,
        taskDir: File,
        processId: String,
    ): File {
        val target = File(taskDir, "${safeFilename(title)}.$extension")
        val connection = URL(directUrl).openConnection() as HttpURLConnection
        connection.instanceFollowRedirects = true
        connection.connectTimeout = 20_000
        connection.readTimeout = 45_000
        connection.setRequestProperty(
            "User-Agent",
            "Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 Chrome/124 Mobile Safari/537.36",
        )
        connection.connect()
        require(connection.responseCode in 200..299) { "媒体服务器返回 ${connection.responseCode}" }
        val total = connection.contentLengthLong
        connection.inputStream.use { input ->
            FileOutputStream(target).use { output ->
                val buffer = ByteArray(256 * 1024)
                var downloaded = 0L
                while (true) {
                    val count = input.read(buffer)
                    if (count < 0) break
                    output.write(buffer, 0, count)
                    downloaded += count
                    val progress = if (total > 0) downloaded * 100.0 / total else 0.0
                    emitProgress(processId, progress, null, "正在下载")
                }
            }
        }
        connection.disconnect()
        return target
    }

    private fun publishToDownloads(source: File): PublishedFile {
        val name = source.name.take(220)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val values = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, name)
                put(MediaStore.MediaColumns.MIME_TYPE, mimeType(name))
                put(
                    MediaStore.MediaColumns.RELATIVE_PATH,
                    "${Environment.DIRECTORY_DOWNLOADS}/langbai解析",
                )
                put(MediaStore.MediaColumns.IS_PENDING, 1)
            }
            val collection = MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
            val uri = contentResolver.insert(collection, values)
                ?: error("无法创建系统下载文件")
            try {
                contentResolver.openOutputStream(uri)?.use { output ->
                    source.inputStream().use { it.copyTo(output) }
                } ?: error("无法写入系统下载文件")
                values.clear()
                values.put(MediaStore.MediaColumns.IS_PENDING, 0)
                contentResolver.update(uri, values, null, null)
                return PublishedFile(name, uri.toString())
            } catch (error: Throwable) {
                contentResolver.delete(uri, null, null)
                throw error
            }
        }

        val base = getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS)
            ?: error("设备没有可用的下载目录")
        val directory = File(base, "langbai解析").apply { mkdirs() }
        val destination = uniqueFile(directory, name)
        source.copyTo(destination, overwrite = false)
        return PublishedFile(destination.name, destination.absolutePath)
    }

    private fun emitProgress(
        processId: String,
        progress: Double,
        etaSeconds: Long?,
        status: String?,
    ) {
        mainHandler.post {
            channel.invokeMethod(
                "downloadProgress",
                mapOf(
                    "process_id" to processId,
                    "progress" to progress.coerceIn(0.0, 100.0),
                    "eta_seconds" to etaSeconds,
                    "status" to status,
                ),
            )
        }
    }

    private fun optionMap(
        id: String,
        kind: String,
        label: String,
        extension: String,
        resolution: String? = null,
        bitrate: Int? = null,
        fps: Double? = null,
        filesize: Long? = null,
        requiresMerge: Boolean = false,
    ): Map<String, Any?> = mapOf(
        "id" to id,
        "kind" to kind,
        "label" to label,
        "extension" to extension,
        "resolution" to resolution,
        "bitrate_kbps" to bitrate,
        "fps" to fps,
        "filesize" to filesize,
        "filesize_label" to filesize?.let(::humanBytes),
        "requires_merge" to requiresMerge,
    )

    private fun text(objectValue: JSONObject, key: String): String? {
        val value = objectValue.opt(key)
        return if (value == null || value == JSONObject.NULL) null else value.toString().trim().ifEmpty { null }
    }

    private fun positiveInt(objectValue: JSONObject, key: String): Int? =
        objectValue.optInt(key, 0).takeIf { it > 0 }

    private fun positiveLong(objectValue: JSONObject, key: String): Long? =
        objectValue.optLong(key, 0).takeIf { it > 0 }

    private fun extensionFromUrl(value: String, fallback: String): String {
        return runCatching {
            val path = Uri.parse(value).lastPathSegment.orEmpty()
            path.substringAfterLast('.', "").lowercase().takeIf { it.length in 2..5 }
        }.getOrNull() ?: fallback
    }

    private fun safeFilename(value: String): String {
        val cleaned = value.replace(Regex("[\\\\/:*?\"<>|\\r\\n]+"), "_").trim().take(160)
        return cleaned.ifEmpty { "langbai-media" }
    }

    private fun uniqueFile(directory: File, name: String): File {
        val direct = File(directory, name)
        if (!direct.exists()) return direct
        val extension = name.substringAfterLast('.', "")
        val stem = name.removeSuffix(if (extension.isEmpty()) "" else ".$extension")
        var index = 2
        while (true) {
            val candidate = File(directory, "$stem ($index)${if (extension.isEmpty()) "" else ".$extension"}")
            if (!candidate.exists()) return candidate
            index += 1
        }
    }

    private fun humanBytes(value: Long): String {
        var size = value.toDouble()
        val units = listOf("B", "KB", "MB", "GB", "TB")
        for (unit in units) {
            if (size < 1024 || unit == units.last()) {
                return if (unit == "B") "${size.toLong()} B" else String.format("%.1f %s", size, unit)
            }
            size /= 1024
        }
        return "$value B"
    }

    private fun mimeType(name: String): String = when (name.substringAfterLast('.', "").lowercase()) {
        "mp4", "m4v" -> "video/mp4"
        "webm" -> "video/webm"
        "mov" -> "video/quicktime"
        "mkv" -> "video/x-matroska"
        "mp3" -> "audio/mpeg"
        "m4a" -> "audio/mp4"
        "flac" -> "audio/flac"
        "wav" -> "audio/wav"
        "ogg", "opus" -> "audio/ogg"
        "png" -> "image/png"
        "webp" -> "image/webp"
        "gif" -> "image/gif"
        else -> "application/octet-stream"
    }

    private fun kindLabel(kind: String): String = when (kind) {
        "audio" -> "音频"
        "image" -> "图片"
        else -> "视频"
    }

    private fun friendlyMessage(error: Throwable): String {
        val raw = generateSequence(error) { it.cause }
            .mapNotNull { it.message?.trim() }
            .firstOrNull { it.isNotEmpty() }
            ?: "本地解析失败"
        val useful = raw.lineSequence()
            .map { it.trim() }
            .filter { it.isNotEmpty() && !it.startsWith("WARNING:") }
            .toList()
            .takeLast(4)
            .joinToString(" ")
            .replace(Regex("ERROR:\\s*"), "")
        return useful.take(500).ifEmpty { "本地解析失败，请更新解析器后重试" }
    }

    private data class LocalMedia(
        val sourceUrl: String,
        val title: String,
        val options: Map<String, LocalOption>,
    )

    private data class LocalOption(
        val kind: String,
        val extension: String,
        val selector: String? = null,
        val audioQuality: String? = null,
        val directUrl: String? = null,
    )

    private data class AudioPreset(
        val id: String,
        val label: String,
        val extension: String,
        val quality: String,
    )

    private data class PublishedFile(val name: String, val location: String)

    companion object {
        private val IMAGE_EXTENSIONS = setOf("jpg", "jpeg", "png", "webp", "avif", "gif")
        private val AUDIO_EXTENSIONS = setOf("mp3", "m4a", "aac", "ogg", "opus", "wav", "flac")
    }
}
