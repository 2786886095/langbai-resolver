package com.langbai.mediaharbor

import android.content.Context
import com.yausername.ffmpeg.FFmpeg
import org.json.JSONObject
import java.io.File
import java.util.Locale
import java.util.concurrent.ConcurrentHashMap

internal class NativeFormatConverter(private val context: Context) {
    private val activeProcesses = ConcurrentHashMap<String, Process>()
    private val cancelled = ConcurrentHashMap.newKeySet<String>()

    data class Progress(
        val percent: Double,
        val status: String,
        val speedBytesPerSecond: Double?,
        val averageSpeedBytesPerSecond: Double?,
    )

    data class Capabilities(
        val inputExtensions: List<String> = (
            VIDEO_INPUTS + AUDIO_INPUTS + IMAGE_INPUTS
            ).sorted(),
        val outputFormats: List<String> = (
            VIDEO_OUTPUTS + AUDIO_OUTPUTS + IMAGE_OUTPUTS
            ).sorted(),
        val qualityValues: List<String> = listOf("low", "medium", "high", "original"),
    )

    fun capabilities(): Capabilities = Capabilities()

    fun probeMedia(input: File): Map<String, Any?> {
        require(input.isFile) { "待检测文件不存在" }
        FFmpeg.getInstance().init(context.applicationContext)
        val command = listOf(
            ffprobeBinary().absolutePath,
            "-v", "error",
            "-show_entries",
            "format=format_name,duration,size,bit_rate:stream=index,codec_type,codec_name,width,height,sample_rate,channels,bit_rate",
            "-of", "json",
            input.absolutePath,
        )
        val process = processBuilder(command).redirectErrorStream(true).start()
        val output = process.inputStream.bufferedReader().readText()
        require(process.waitFor() == 0) { "无法读取媒体信息，请确认文件没有损坏" }
        val root = runCatching { JSONObject(output) }
            .getOrElse { error("媒体信息格式不正确") }
        val format = root.optJSONObject("format") ?: JSONObject()
        val streamsJson = root.optJSONArray("streams")
        val streams = mutableListOf<Map<String, Any?>>()
        var hasVideo = false
        var hasAudio = false
        var width: Int? = null
        var height: Int? = null
        if (streamsJson != null) {
            for (index in 0 until streamsJson.length()) {
                val stream = streamsJson.optJSONObject(index) ?: continue
                val type = stream.optString("codec_type").takeIf { it.isNotBlank() }
                if (type == "video") hasVideo = true
                if (type == "audio") hasAudio = true
                val streamWidth = stream.optInt("width", 0).takeIf { it > 0 }
                val streamHeight = stream.optInt("height", 0).takeIf { it > 0 }
                if (type == "video" && (streamWidth ?: 0) * (streamHeight ?: 0) > (width ?: 0) * (height ?: 0)) {
                    width = streamWidth
                    height = streamHeight
                }
                streams += mapOf(
                    "index" to stream.optInt("index", index),
                    "type" to type,
                    "codec" to stream.optString("codec_name").takeIf { it.isNotBlank() },
                    "width" to streamWidth,
                    "height" to streamHeight,
                    "sample_rate" to stream.optString("sample_rate").toIntOrNull(),
                    "channels" to stream.optInt("channels", 0).takeIf { it > 0 },
                    "bitrate_bps" to stream.optString("bit_rate").toLongOrNull(),
                )
            }
        }
        val extension = input.extension.lowercase(Locale.ROOT)
        return mapOf(
            "filename" to input.name,
            "extension" to extension,
            "mime_type" to mimeType(extension),
            "size_bytes" to input.length(),
            "duration_seconds" to format.optString("duration").toDoubleOrNull(),
            "width" to width,
            "height" to height,
            "has_video" to hasVideo,
            "has_audio" to hasAudio,
            "format_name" to format.optString("format_name").takeIf { it.isNotBlank() },
            "bitrate_bps" to format.optString("bit_rate").toLongOrNull(),
            "streams" to streams,
        )
    }

    fun cancel(processId: String): Boolean {
        if (processId.isBlank()) return false
        val process = activeProcesses[processId] ?: return false
        val requested = cancelled.add(processId)
        val wasRunning = isProcessRunning(process)
        process.destroy()
        return requested || wasRunning
    }

    fun cancelAll() {
        activeProcesses.keys.toList().forEach(::cancel)
    }

    fun convert(
        processId: String,
        input: File,
        outputDirectory: File,
        outputFormat: String,
        quality: String,
        isCancelled: () -> Boolean = { false },
        onProgress: (Progress) -> Unit,
    ): File {
        require(processId.isNotBlank()) { "转换任务编号不能为空" }
        require(input.isFile) { "待转换文件不存在" }
        val format = outputFormat.trim().lowercase(Locale.ROOT).removePrefix(".")
        require(format in ALL_OUTPUTS) { "Android 暂不支持转换为 $format" }
        require(quality in QUALITY_VALUES) { "转换质量参数不正确" }
        outputDirectory.mkdirs()
        require(outputDirectory.isDirectory) { "无法创建转换目录" }
        cancelled.remove(processId)
        FFmpeg.getInstance().init(context.applicationContext)

        val probe = probe(input)
        validatePair(input.extension.lowercase(Locale.ROOT), format, probe)
        val output = File(outputDirectory, "${input.nameWithoutExtension.take(140)}.$format")
        if (output.exists()) output.delete()
        val command = buildList {
            add(ffmpegBinary().absolutePath)
            addAll(listOf("-hide_banner", "-nostdin", "-y", "-i", input.absolutePath))
            addAll(conversionArguments(format, quality))
            addAll(listOf("-progress", "pipe:1", "-nostats", output.absolutePath))
        }
        val process = processBuilder(command).redirectErrorStream(true).start()
        check(activeProcesses.putIfAbsent(processId, process) == null) {
            process.destroy()
            "同一转换任务已在运行"
        }
        if (isCancelled()) {
            cancelled.add(processId)
            process.destroy()
        }
        val startedAt = System.nanoTime()
        var lastAt = startedAt
        var lastBytes = 0L
        var outTimeMicros = 0L
        try {
            onProgress(Progress(0.0, "正在准备转换", null, null))
            process.inputStream.bufferedReader().useLines { lines ->
                lines.forEach { line ->
                    if (processId in cancelled || isCancelled()) {
                        cancelled.add(processId)
                        process.destroy()
                        return@forEach
                    }
                    when {
                        line.startsWith("out_time_us=") -> {
                            outTimeMicros = line.substringAfter('=').toLongOrNull() ?: outTimeMicros
                        }
                        line.startsWith("out_time_ms=") && outTimeMicros == 0L -> {
                            // Older builds use this misleading key for microseconds.
                            outTimeMicros = line.substringAfter('=').toLongOrNull() ?: outTimeMicros
                        }
                        line == "progress=continue" || line == "progress=end" -> {
                            val now = System.nanoTime()
                            val bytes = output.length()
                            val sampleSeconds = (now - lastAt) / 1_000_000_000.0
                            val elapsedSeconds = (now - startedAt) / 1_000_000_000.0
                            val instant = if (sampleSeconds > 0) {
                                (bytes - lastBytes).coerceAtLeast(0).toDouble() / sampleSeconds
                            } else null
                            val average = if (elapsedSeconds > 0) bytes / elapsedSeconds else null
                            val percent = if (line == "progress=end") {
                                100.0
                            } else if (probe.durationSeconds > 0) {
                                (outTimeMicros / 1_000_000.0 * 100.0 / probe.durationSeconds)
                                    .coerceIn(0.0, 99.5)
                            } else {
                                0.0
                            }
                            onProgress(Progress(percent, "正在转换", instant, average))
                            lastAt = now
                            lastBytes = bytes
                        }
                    }
                }
            }
            val exitCode = process.waitFor()
            if (processId in cancelled || isCancelled()) {
                output.delete()
                error("转换已取消")
            }
            require(exitCode == 0 && output.isFile && output.length() > 0) {
                "格式转换失败，请确认源文件完整且编码受支持"
            }
            val elapsed = (System.nanoTime() - startedAt) / 1_000_000_000.0
            onProgress(
                Progress(
                    100.0,
                    "转换完成",
                    null,
                    if (elapsed > 0) output.length() / elapsed else null,
                ),
            )
            return output
        } finally {
            activeProcesses.remove(processId, process)
            cancelled.remove(processId)
            if (isProcessRunning(process)) process.destroy()
        }
    }

    private fun isProcessRunning(process: Process): Boolean = try {
        process.exitValue()
        false
    } catch (_: IllegalThreadStateException) {
        true
    }

    private fun validatePair(inputExtension: String, output: String, probe: Probe) {
        when (output) {
            in VIDEO_OUTPUTS -> require(
                probe.hasVideo && (inputExtension !in IMAGE_INPUTS || inputExtension == "gif"),
            ) {
                "该源文件不能转换为视频"
            }
            "gif" -> require(probe.hasVideo) { "该源文件不能转换为 GIF" }
            in AUDIO_OUTPUTS -> require(probe.hasAudio) { "源文件不包含可转换的音轨" }
            in IMAGE_OUTPUTS -> require(probe.hasVideo) {
                "源文件不包含可转换的图像或视频画面"
            }
        }
    }

    private fun conversionArguments(format: String, quality: String): List<String> {
        val videoQuality = mapOf("low" to "12", "medium" to "7", "high" to "3", "original" to "2")
            .getValue(quality)
        val audioBitrate = mapOf("low" to "96k", "medium" to "160k", "high" to "256k", "original" to "320k")
            .getValue(quality)
        val modernVideoCrf = mapOf("low" to "38", "medium" to "31", "high" to "25", "original" to "19")
            .getValue(quality)
        return when (format) {
            "mp4", "mov" -> listOf(
                "-map", "0:v:0", "-map", "0:a?", "-c:v", "mpeg4", "-q:v", videoQuality,
                "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", audioBitrate,
                "-movflags", "+faststart",
            )
            "m4v" -> listOf(
                "-map", "0:v:0", "-map", "0:a?", "-c:v", "mpeg4", "-q:v", videoQuality,
                "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", audioBitrate,
                "-movflags", "+faststart", "-f", "mp4",
            )
            "mkv" -> listOf(
                "-map", "0:v:0", "-map", "0:a?", "-c:v", "mpeg4", "-q:v", videoQuality,
                "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", audioBitrate,
            )
            "webm" -> listOf(
                "-map", "0:v:0", "-map", "0:a?", "-c:v", "libvpx-vp9",
                "-crf", modernVideoCrf, "-b:v", "0", "-row-mt", "1",
                "-c:a", "libopus", "-b:a", audioBitrate,
            )
            "avi" -> listOf(
                "-map", "0:v:0", "-map", "0:a?", "-c:v", "mpeg4", "-q:v", videoQuality,
                "-c:a", "libmp3lame", "-b:a", audioBitrate,
            )
            "ts" -> listOf(
                "-map", "0:v:0", "-map", "0:a?", "-c:v", "mpeg2video", "-q:v", videoQuality,
                "-c:a", "aac", "-b:a", audioBitrate, "-f", "mpegts",
            )
            "gif" -> listOf("-map", "0:v:0", "-vf", "fps=${if (quality == "low") 10 else 15}", "-loop", "0")
            "mp3" -> listOf("-vn", "-c:a", "libmp3lame", "-b:a", audioBitrate)
            "m4a", "aac" -> listOf("-vn", "-c:a", "aac", "-b:a", audioBitrate)
            "wav" -> listOf("-vn", "-c:a", "pcm_s16le")
            "flac" -> listOf("-vn", "-c:a", "flac", "-compression_level", if (quality == "low") "3" else "8")
            "ogg" -> listOf("-vn", "-c:a", "libvorbis", "-q:a", if (quality == "low") "3" else "7")
            "opus" -> listOf("-vn", "-c:a", "libopus", "-b:a", audioBitrate)
            "ac3" -> listOf("-vn", "-c:a", "ac3", "-b:a", if (quality == "low") "192k" else "384k")
            "aiff", "aif" -> listOf("-vn", "-c:a", "pcm_s16be")
            "jpg", "jpeg" -> listOf("-frames:v", "1", "-q:v", if (quality == "low") "8" else "2")
            "png" -> listOf("-frames:v", "1", "-compression_level", if (quality == "low") "9" else "4")
            "webp" -> listOf("-frames:v", "1", "-c:v", "libwebp", "-quality", if (quality == "low") "65" else "92")
            "bmp" -> listOf("-frames:v", "1")
            "tiff", "tif" -> listOf("-frames:v", "1", "-c:v", "tiff")
            else -> error("Android 暂不支持该输出格式")
        }
    }

    private fun probe(input: File): Probe {
        val command = listOf(
            ffprobeBinary().absolutePath,
            "-v", "error",
            "-show_entries", "format=duration:stream=codec_type",
            "-of", "default=noprint_wrappers=1",
            input.absolutePath,
        )
        val process = processBuilder(command).redirectErrorStream(true).start()
        val output = process.inputStream.bufferedReader().readText()
        require(process.waitFor() == 0) { "无法读取源文件，请确认文件没有损坏" }
        return Probe(
            hasVideo = "codec_type=video" in output,
            hasAudio = "codec_type=audio" in output,
            durationSeconds = Regex("duration=([0-9.]+)").find(output)
                ?.groupValues?.get(1)?.toDoubleOrNull() ?: 0.0,
        )
    }

    private fun processBuilder(command: List<String>): ProcessBuilder = ProcessBuilder(command).apply {
        val ffmpegLibraries = File(
            context.noBackupFilesDir,
            "youtubedl-android/packages/ffmpeg/usr/lib",
        )
        environment()["LD_LIBRARY_PATH"] = listOf(
            ffmpegLibraries.absolutePath,
            context.applicationInfo.nativeLibraryDir,
        ).joinToString(":")
        environment()["TMPDIR"] = context.cacheDir.absolutePath
    }

    private fun ffmpegBinary() = File(context.applicationInfo.nativeLibraryDir, "libffmpeg.so").also {
        require(it.isFile) { "内置 FFmpeg 不可用" }
    }

    private fun ffprobeBinary() = File(context.applicationInfo.nativeLibraryDir, "libffprobe.so").also {
        require(it.isFile) { "内置 FFprobe 不可用" }
    }

    private fun mimeType(extension: String): String = when (extension) {
        "mp4", "m4v" -> "video/mp4"
        "mov" -> "video/quicktime"
        "mkv" -> "video/x-matroska"
        "webm" -> "video/webm"
        "avi" -> "video/x-msvideo"
        "ts" -> "video/mp2t"
        "mp3" -> "audio/mpeg"
        "m4a", "aac" -> "audio/mp4"
        "wav" -> "audio/wav"
        "flac" -> "audio/flac"
        "ogg", "opus" -> "audio/ogg"
        "ac3" -> "audio/ac3"
        "aiff", "aif" -> "audio/aiff"
        "jpg", "jpeg" -> "image/jpeg"
        "png" -> "image/png"
        "webp" -> "image/webp"
        "heic", "heif" -> "image/heic"
        "tiff", "tif" -> "image/tiff"
        else -> "application/octet-stream"
    }

    private data class Probe(
        val hasVideo: Boolean,
        val hasAudio: Boolean,
        val durationSeconds: Double,
    )

    companion object {
        private val VIDEO_INPUTS = setOf(
            "mp4", "m4v", "mov", "mkv", "webm", "avi", "flv", "ts", "mts", "m2ts",
            "3gp", "wmv", "mpeg", "mpg", "vob", "ogv", "asf",
        )
        private val AUDIO_INPUTS = setOf(
            "mp3", "m4a", "aac", "wav", "flac", "ogg", "opus", "wma", "amr", "aiff",
            "aif", "ac3", "eac3", "dts", "ape", "alac",
        )
        private val IMAGE_INPUTS = setOf(
            "jpg", "jpeg", "png", "webp", "bmp", "gif", "heic", "heif", "avif", "tiff",
            "tif", "tga",
        )
        private val VIDEO_OUTPUTS = setOf("mp4", "m4v", "mov", "mkv", "webm", "avi", "ts")
        private val AUDIO_OUTPUTS = setOf(
            "mp3", "m4a", "aac", "wav", "flac", "ogg", "opus", "ac3", "aiff", "aif",
        )
        private val IMAGE_OUTPUTS = setOf(
            "jpg", "jpeg", "png", "webp", "bmp", "tiff", "tif",
        )
        private val ALL_OUTPUTS = VIDEO_OUTPUTS + AUDIO_OUTPUTS + IMAGE_OUTPUTS + "gif"
        private val QUALITY_VALUES = setOf("low", "medium", "high", "original")
    }
}
