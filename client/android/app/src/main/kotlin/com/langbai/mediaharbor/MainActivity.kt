package com.langbai.mediaharbor

import android.Manifest
import android.content.ContentValues
import android.content.pm.PackageManager
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
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
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import java.io.InputStream
import java.net.CookieManager
import java.net.CookiePolicy
import java.net.HttpURLConnection
import java.net.URI
import java.net.URL
import java.util.UUID
import java.util.Locale
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.locks.ReentrantReadWriteLock
import kotlin.concurrent.read
import kotlin.concurrent.write

class MainActivity : FlutterActivity() {
    private val worker = Executors.newFixedThreadPool(3)
    private val mainHandler = Handler(Looper.getMainLooper())
    private val resolved = ConcurrentHashMap<String, LocalMedia>()
    private val activeConnections = ConcurrentHashMap<String, HttpURLConnection>()
    private val cancelledProcesses = ConcurrentHashMap.newKeySet<String>()
    private val progressState = ConcurrentHashMap<String, ProgressState>()
    private val pendingStoragePermissions = mutableListOf<PendingStoragePermission>()
    private val engineLock = ReentrantReadWriteLock()
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
        activeConnections.values.forEach { it.disconnect() }
        activeConnections.clear()
        worker.shutdownNow()
        super.onDestroy()
    }

    private fun handleMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "isAvailable" -> result.success(true)
            "getCapabilities" -> result.success(capabilities())
            "resolve" -> runAsync(result) {
                val input = call.argument<String>("url")?.trim().orEmpty()
                val url = extractHttpUrl(input)
                    ?: error("未在粘贴内容中找到 http 或 https 链接")
                val bilibiliCookie = cleanBilibiliCookie(
                    call.argument<String>("bilibili_cookie"),
                    url,
                )
                resolveLocally(url, bilibiliCookie)
            }
            "download" -> withLegacyStoragePermission(result) {
                runAsync(result) {
                    val mediaId = call.argument<String>("media_id").orEmpty()
                    val optionId = call.argument<String>("option_id").orEmpty()
                    val processId = call.argument<String>("process_id") ?: UUID.randomUUID().toString()
                    val destination = call.argument<String>("save_destination") ?: "files"
                    downloadLocally(mediaId, optionId, processId, destination)
                }
            }
            "saveMobileFile" -> withLegacyStoragePermission(result) {
                runAsync(result) {
                    val path = call.argument<String>("path").orEmpty()
                    val source = File(path)
                    require(source.isFile) { "待保存文件不存在" }
                    val destination = call.argument<String>("save_destination") ?: "files"
                    val mediaType = call.argument<String>("media_type") ?: "file"
                    val published = if (destination == "gallery") {
                        require(mediaType == "image" || mediaType == "video") {
                            "只有图片和视频可以保存到相册"
                        }
                        publishToGallery(source, mediaType)
                    } else {
                        publishToDownloads(source)
                    }
                    mapOf(
                        "filename" to published.name,
                        "path" to published.location,
                        "message" to if (destination == "gallery") {
                            "已保存到系统相册"
                        } else {
                            "已保存到 Download/langbai解析/${published.name}"
                        },
                    )
                }
            }
            "cancelDownload" -> {
                val processId = call.argument<String>("process_id").orEmpty()
                result.success(mapOf("cancelled" to cancelDownload(processId)))
            }
            "clearSession" -> {
                clearSession()
                result.success(mapOf("cleared" to true))
            }
            "updateEngine" -> runAsync(result) {
                engineLock.write {
                    ensureEngine()
                    YoutubeDL.getInstance().updateYoutubeDL(
                        applicationContext,
                        YoutubeDL.UpdateChannel.STABLE,
                    )
                    mapOf(
                        "version" to (YoutubeDL.getInstance().versionName(applicationContext) ?: "最新版本"),
                    )
                }
            }
            else -> result.notImplemented()
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != STORAGE_PERMISSION_REQUEST) return
        val granted = grantResults.isNotEmpty() && grantResults.all { it == PackageManager.PERMISSION_GRANTED }
        val pending = synchronized(pendingStoragePermissions) {
            pendingStoragePermissions.toList().also { pendingStoragePermissions.clear() }
        }
        pending.forEach { item ->
            if (granted) {
                item.action()
            } else {
                item.result.error(
                    "STORAGE_PERMISSION_DENIED",
                    "需要存储权限才能保存到公共 Download 或系统相册",
                    null,
                )
            }
        }
    }

    private fun withLegacyStoragePermission(
        result: MethodChannel.Result,
        action: () -> Unit,
    ) {
        if (
            Build.VERSION.SDK_INT > Build.VERSION_CODES.P ||
            ContextCompat.checkSelfPermission(this, Manifest.permission.WRITE_EXTERNAL_STORAGE) ==
            PackageManager.PERMISSION_GRANTED
        ) {
            action()
            return
        }
        val shouldRequest = synchronized(pendingStoragePermissions) {
            pendingStoragePermissions += PendingStoragePermission(result, action)
            pendingStoragePermissions.size == 1
        }
        if (shouldRequest) {
            ActivityCompat.requestPermissions(
                this,
                arrayOf(Manifest.permission.WRITE_EXTERNAL_STORAGE),
                STORAGE_PERMISSION_REQUEST,
            )
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

    private fun capabilities(): Map<String, Any?> = mapOf(
        "platform" to "android",
        "local_resolver" to true,
        "engine_update" to true,
        "download_progress" to true,
        "download_cancellation" to true,
        // The embedded parser cannot safely continue after the app process is killed.
        "background_download" to false,
        "save_to_files" to true,
        "save_to_gallery" to true,
        "tools" to mapOf(
            "resolve" to true,
            "audio_extract" to false,
            "compress" to false,
            "web_sniff" to false,
            "direct_download" to false,
            "magnet" to false,
            "torrent" to false,
            "metadata" to false,
            "music_search" to true,
        ),
    )

    private fun cancelDownload(processId: String): Boolean {
        if (processId.isBlank()) return false
        val requested = cancelledProcesses.add(processId)
        val disconnected = activeConnections.remove(processId)?.let {
            it.disconnect()
            true
        } ?: false
        val stopped = runCatching { YoutubeDL.getInstance().destroyProcessById(processId) }
            .getOrDefault(false)
        return requested || disconnected || stopped || progressState.containsKey(processId)
    }

    private fun clearSession() {
        resolved.clear()
        (activeConnections.keys + progressState.keys).toSet().forEach(::cancelDownload)
        cacheDir.listFiles()
            ?.filter { it.name.startsWith("langbai-bilibili-") }
            ?.forEach(File::delete)
    }

    @Synchronized
    private fun ensureEngine() {
        if (engineReady) return
        YoutubeDL.getInstance().init(applicationContext)
        FFmpeg.getInstance().init(applicationContext)
        Aria2c.getInstance().init(applicationContext)
        engineReady = true
    }

    private fun resolveLocally(url: String, bilibiliCookie: String?): Map<String, Any?> {
        if (isKuaishouUrl(url)) {
            return resolveKuaishouShare(url)
        }
        if (isDouyinUrl(url)) {
            return resolveDouyinShare(url)
        }
        ensureEngine()
        val response = engineLock.read {
            withBilibiliCookieFile(bilibiliCookie) { cookieFile ->
                val request = YoutubeDLRequest(url)
                    .addOption("--dump-single-json")
                    .addOption("--no-playlist")
                    .addOption("--skip-download")
                    .addOption("--socket-timeout", "25")
                    .addOption("--retries", "2")
                cookieFile?.let { request.addOption("--cookies", it.absolutePath) }
                YoutubeDL.getInstance().execute(request)
            }
        }
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
                headers = safeHttpHeaders(effective.optJSONObject("http_headers")),
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
        resolved[mediaId] = LocalMedia(sourceUrl, title, specs, bilibiliCookie)
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
            "warnings" to listOfNotNull(
                bilibiliCookie?.let { "已使用本机加密保存的B站登录会话请求最高画质。" },
                "由 Android 本机解析，媒体链接不会发送到 langbai 服务器。",
            ),
        )
    }

    private fun extractHttpUrl(value: String): String? =
        Regex("https?://[^\\s<>\\\"']+", RegexOption.IGNORE_CASE)
            .find(value)
            ?.value
            ?.trimEnd(')', ']', '}', '>', '，', '。', '！', '？', '；', '：', '、')

    private fun cleanBilibiliCookie(value: String?, url: String): String? {
        if (value.isNullOrBlank() || !isBilibiliUrl(url) || '\r' in value || '\n' in value) return null
        val pairs = value.split(';').mapNotNull { item ->
            val name = item.substringBefore('=', "").trim()
            val content = item.substringAfter('=', "").trim()
            if (name in BILIBILI_COOKIE_NAMES && content.isNotEmpty()) "$name=$content" else null
        }
        return pairs.joinToString("; ").takeIf { pairs.any { it.startsWith("SESSDATA=") } }
    }

    private fun isBilibiliUrl(value: String): Boolean {
        val host = runCatching { Uri.parse(value).host.orEmpty().lowercase() }.getOrDefault("")
        return host == "b23.tv" || host == "bilibili.com" || host.endsWith(".bilibili.com")
    }

    private fun <T> withBilibiliCookieFile(cookie: String?, action: (File?) -> T): T {
        if (cookie.isNullOrBlank()) return action(null)
        val file = File.createTempFile("langbai-bilibili-", ".txt", cacheDir)
        return try {
            val expires = System.currentTimeMillis() / 1000 + 30L * 24 * 60 * 60
            val lines = mutableListOf("# Netscape HTTP Cookie File")
            cookie.split(';').forEach { item ->
                val name = item.substringBefore('=', "").trim()
                val value = item.substringAfter('=', "").trim()
                if (name in BILIBILI_COOKIE_NAMES && value.isNotEmpty()) {
                    lines += ".bilibili.com\tTRUE\t/\tTRUE\t$expires\t$name\t$value"
                }
            }
            file.writeText(lines.joinToString("\n", postfix = "\n"), Charsets.UTF_8)
            action(file)
        } finally {
            file.delete()
        }
    }

    private fun isDouyinUrl(value: String): Boolean {
        val host = runCatching { Uri.parse(value).host.orEmpty().lowercase() }.getOrDefault("")
        return host == "douyin.com" || host.endsWith(".douyin.com") ||
            host == "iesdouyin.com" || host.endsWith(".iesdouyin.com")
    }

    private fun isKuaishouUrl(value: String): Boolean {
        val host = runCatching { Uri.parse(value).host.orEmpty().lowercase() }.getOrDefault("")
        return KUAISHOU_HOSTS.any { host == it || host.endsWith(".$it") }
    }

    private fun fetchKuaishouPage(sourceUrl: String): Pair<String, String> {
        val cookieManager = CookieManager(null, CookiePolicy.ACCEPT_ALL)
        var current = sourceUrl
        repeat(8) {
            require(isKuaishouUrl(current)) { "快手短链接跳转到了未知站点" }
            val uri = URI(current)
            val connection = URL(current).openConnection() as HttpURLConnection
            connection.instanceFollowRedirects = false
            connection.connectTimeout = 15_000
            connection.readTimeout = 25_000
            connection.setRequestProperty("User-Agent", KUAISHOU_MOBILE_USER_AGENT)
            connection.setRequestProperty(
                "Accept",
                "text/html,application/xhtml+xml,application/json;q=0.9,*/*;q=0.8",
            )
            connection.setRequestProperty("Accept-Language", "zh-CN,zh;q=0.9")
            connection.setRequestProperty("Referer", "https://v.kuaishou.com/")
            cookieManager.get(uri, emptyMap())["Cookie"]
                ?.takeIf { it.isNotEmpty() }
                ?.let { connection.setRequestProperty("Cookie", it.joinToString("; ")) }
            connection.connect()
            val responseCode = connection.responseCode
            val responseHeaders = connection.headerFields
                .filterKeys { it != null }
                .mapKeys { it.key!! }
            cookieManager.put(uri, responseHeaders)
            val location = connection.getHeaderField("Location")
            if (responseCode in 300..399 && !location.isNullOrBlank()) {
                current = URL(URL(current), location).toString()
                connection.disconnect()
                return@repeat
            }
            require(responseCode in 200..299) { "快手匿名分享页返回 $responseCode" }
            val html = connection.inputStream.use(::readLimitedHtml)
            val finalUrl = connection.url.toString()
            connection.disconnect()
            require(isKuaishouUrl(finalUrl)) { "快手短链接跳转到了未知站点" }
            return finalUrl to html
        }
        error("快手短链接跳转次数过多")
    }

    private fun findKuaishouPhoto(value: Any?, depth: Int = 0): JSONObject? {
        if (depth > 6) return null
        when (value) {
            is JSONObject -> {
                value.optJSONObject("photo")?.let { return it }
                val keys = value.keys()
                while (keys.hasNext()) {
                    findKuaishouPhoto(value.opt(keys.next()), depth + 1)?.let { return it }
                }
            }
            is JSONArray -> {
                for (index in 0 until value.length()) {
                    findKuaishouPhoto(value.opt(index), depth + 1)?.let { return it }
                }
            }
        }
        return null
    }

    private fun firstKuaishouUrl(values: JSONArray?): String? {
        if (values == null) return null
        for (index in 0 until values.length()) {
            val item = values.opt(index)
            val candidate = when (item) {
                is JSONObject -> text(item, "url")
                else -> item?.toString()?.trim()
            }
            if (candidate?.startsWith("http://") == true || candidate?.startsWith("https://") == true) {
                return candidate
            }
        }
        return null
    }

    private fun resolveKuaishouShare(sourceUrl: String): Map<String, Any?> {
        val (_, html) = fetchKuaishouPage(sourceUrl)
        val marker = "window.INIT_STATE ="
        val markerIndex = html.indexOf(marker)
        val jsonStart = html.indexOf('{', markerIndex + marker.length)
        val scriptEnd = html.indexOf("</script>", jsonStart)
        require(markerIndex >= 0 && jsonStart >= 0 && scriptEnd > jsonStart) {
            "快手匿名分享页没有内嵌作品数据"
        }
        val state = JSONObject(html.substring(jsonStart, scriptEnd).trim().removeSuffix(";"))
        val photo = findKuaishouPhoto(state) ?: error("快手匿名分享页没有返回作品详情")
        val specs = linkedMapOf<String, LocalOption>()
        val options = mutableListOf<Map<String, Any?>>()
        val width = positiveInt(photo, "width")
        val height = positiveInt(photo, "height")
        val playUrl = firstKuaishouUrl(photo.optJSONArray("mainMvUrls"))
        if (playUrl != null) {
            val id = "video:kuaishou-share"
            specs[id] = LocalOption(
                "video",
                "mp4",
                directUrl = playUrl,
                headers = mapOf(
                    "User-Agent" to KUAISHOU_MOBILE_USER_AGENT,
                    "Referer" to "https://v.kuaishou.com/",
                ),
            )
            options += optionMap(
                id = id,
                kind = "video",
                label = "快手公开视频 · MP4",
                extension = "mp4",
                resolution = if (width != null && height != null) "${width}x$height" else null,
            )
        }

        val imageUrls = linkedSetOf<String>()
        val coverUrl = firstKuaishouUrl(photo.optJSONArray("coverUrls"))
        if (coverUrl != null) imageUrls += coverUrl
        for (key in listOf("imageUrls", "images")) {
            val values = photo.optJSONArray(key) ?: continue
            for (index in 0 until values.length()) {
                val item = values.opt(index)
                val imageUrl = when (item) {
                    is JSONObject -> text(item, "url") ?: firstKuaishouUrl(item.optJSONArray("urls"))
                    else -> item?.toString()?.trim()
                }
                if (imageUrl?.startsWith("http://") == true || imageUrl?.startsWith("https://") == true) {
                    imageUrls += imageUrl
                }
                if (imageUrls.size >= 40) break
            }
        }
        imageUrls.forEachIndexed { index, imageUrl ->
            val isCover = imageUrl == coverUrl
            val id = if (isCover) "image:cover" else "image:${index + 1}"
            val extension = extensionFromUrl(imageUrl, "jpg")
            specs[id] = LocalOption(
                "image",
                extension,
                directUrl = imageUrl,
                headers = mapOf("User-Agent" to KUAISHOU_MOBILE_USER_AGENT),
            )
            options += optionMap(
                id = id,
                kind = "image",
                label = if (isCover) "最高质量封面" else "图片 ${index + 1}",
                extension = extension,
            )
        }
        require(options.isNotEmpty()) { "快手匿名分享页没有返回视频或图片地址" }

        val mediaId = UUID.randomUUID().toString()
        val photoId = text(photo, "photoId")
        val title = text(photo, "caption") ?: photoId?.let { "快手作品 $it" } ?: "快手作品"
        resolved[mediaId] = LocalMedia(sourceUrl, title, specs)
        val durationMs = positiveInt(photo, "duration")
            ?: photo.optJSONObject("ext_params")?.let { positiveInt(it, "sound") }
        return mapOf(
            "media_id" to mediaId,
            "source_url" to sourceUrl,
            "title" to title,
            "creator" to text(photo, "userName"),
            "platform" to "Kuaishou",
            "duration_seconds" to durationMs?.div(1000),
            "thumbnail_url" to coverUrl,
            "options" to options,
            "warnings" to listOf("不读取或发送你的登录 Cookie；匿名分享页可能使用站点临时 Cookie。"),
        )
    }

    private fun douyinVideoId(value: String): String? {
        Regex("/(?:video|note)/(\\d{10,})").find(value)?.let { return it.groupValues[1] }
        val uri = runCatching { Uri.parse(value) }.getOrNull() ?: return null
        for (key in listOf("modal_id", "aweme_id", "item_id")) {
            uri.getQueryParameter(key)?.takeIf { it.matches(Regex("\\d{10,}")) }?.let { return it }
        }
        return null
    }

    private fun resolveDouyinShare(sourceUrl: String): Map<String, Any?> {
        var videoId = douyinVideoId(sourceUrl)
        var current = sourceUrl
        repeat(5) {
            if (videoId != null) return@repeat
            val connection = URL(current).openConnection() as HttpURLConnection
            connection.instanceFollowRedirects = false
            connection.connectTimeout = 15_000
            connection.readTimeout = 20_000
            connection.setRequestProperty("User-Agent", DOUYIN_MOBILE_USER_AGENT)
            connection.connect()
            val location = connection.getHeaderField("Location")
            val responseCode = connection.responseCode
            if (responseCode in 300..399 && !location.isNullOrBlank()) {
                current = URL(URL(current), location).toString()
                require(isDouyinUrl(current)) { "抖音短链接跳转到了未知站点" }
                videoId = douyinVideoId(current)
            } else {
                require(responseCode in 200..299) { "抖音短链接返回 $responseCode" }
                val html = connection.inputStream.use(::readLimitedHtml)
                videoId = douyinVideoId(connection.url.toString())
                    ?: Regex("(?:video|note)[/\\\\\"]+(\\d{10,})").find(html)?.groupValues?.get(1)
            }
            connection.disconnect()
        }
        require(!videoId.isNullOrBlank()) { "无法从抖音链接识别作品 ID" }

        val shareUrl = "https://www.iesdouyin.com/share/video/$videoId/"
        val connection = URL(shareUrl).openConnection() as HttpURLConnection
        connection.instanceFollowRedirects = false
        connection.connectTimeout = 15_000
        connection.readTimeout = 25_000
        connection.setRequestProperty("User-Agent", DOUYIN_MOBILE_USER_AGENT)
        connection.connect()
        require(connection.responseCode in 200..299) {
            "抖音匿名分享页返回 ${connection.responseCode}"
        }
        val html = connection.inputStream.use(::readLimitedHtml)
        connection.disconnect()
        val marker = "window._ROUTER_DATA ="
        val markerIndex = html.indexOf(marker)
        require(markerIndex >= 0) { "匿名分享页没有内嵌作品数据" }
        val jsonStart = html.indexOf('{', markerIndex + marker.length)
        val scriptEnd = html.indexOf("</script>", jsonStart)
        require(jsonStart >= 0 && scriptEnd > jsonStart) { "匿名分享页作品数据不完整" }
        val routerData = JSONObject(html.substring(jsonStart, scriptEnd).trim().removeSuffix(";"))
        val loaderData = routerData.optJSONObject("loaderData") ?: error("匿名分享页缺少作品数据")
        var pageData: JSONObject? = null
        val loaderKeys = loaderData.keys()
        while (loaderKeys.hasNext()) {
            val candidate = loaderData.optJSONObject(loaderKeys.next()) ?: continue
            if (candidate.optJSONObject("videoInfoRes") != null) {
                pageData = candidate
                break
            }
        }
        val itemList = pageData?.optJSONObject("videoInfoRes")?.optJSONArray("item_list")
            ?: error("匿名分享页没有返回作品详情")
        var item: JSONObject? = null
        for (index in 0 until itemList.length()) {
            val candidate = itemList.optJSONObject(index) ?: continue
            if (text(candidate, "aweme_id") == videoId || item == null) item = candidate
            if (text(candidate, "aweme_id") == videoId) break
        }
        val detail = item ?: error("匿名分享页没有返回作品详情")
        val video = detail.optJSONObject("video") ?: JSONObject()
        val specs = linkedMapOf<String, LocalOption>()
        val options = mutableListOf<Map<String, Any?>>()
        val playUrl = firstHttpUrl(video.optJSONObject("play_addr")?.optJSONArray("url_list"))
        val width = positiveInt(video, "width")
        val height = positiveInt(video, "height")
        if (playUrl != null) {
            val resolution = Uri.parse(playUrl).getQueryParameter("ratio")
                ?: if (width != null && height != null) "${width}x$height" else null
            val id = "video:douyin-share"
            specs[id] = LocalOption(
                "video",
                "mp4",
                directUrl = playUrl,
                headers = mapOf("User-Agent" to DOUYIN_MOBILE_USER_AGENT),
            )
            options += optionMap(
                id = id,
                kind = "video",
                label = "抖音公开视频 · MP4",
                extension = "mp4",
                resolution = resolution,
            )
        }
        val coverUrl = firstHttpUrl(video.optJSONObject("cover")?.optJSONArray("url_list"))
        if (coverUrl != null) {
            val extension = extensionFromUrl(coverUrl, "jpg")
            specs["image:cover"] = LocalOption(
                "image",
                extension,
                directUrl = coverUrl,
                headers = mapOf("User-Agent" to DOUYIN_MOBILE_USER_AGENT),
            )
            options += optionMap(
                id = "image:cover",
                kind = "image",
                label = "最高质量封面",
                extension = extension,
            )
        }
        val images = detail.optJSONArray("images")
        if (images != null) {
            for (index in 0 until minOf(images.length(), 20)) {
                val image = images.optJSONObject(index) ?: continue
                val imageUrl = firstHttpUrl(
                    image.optJSONArray("url_list") ?: image.optJSONArray("download_url_list"),
                ) ?: continue
                val id = "image:${index + 1}"
                val extension = extensionFromUrl(imageUrl, "jpg")
                specs[id] = LocalOption(
                    "image",
                    extension,
                    directUrl = imageUrl,
                    headers = mapOf("User-Agent" to DOUYIN_MOBILE_USER_AGENT),
                )
                options += optionMap(id, "image", "图片 ${index + 1}", extension)
            }
        }
        require(options.isNotEmpty()) { "匿名分享页没有返回视频或图片地址" }
        val mediaId = UUID.randomUUID().toString()
        val title = text(detail, "desc") ?: "抖音作品 $videoId"
        val author = detail.optJSONObject("author")
        resolved[mediaId] = LocalMedia(sourceUrl, title, specs)
        return mapOf(
            "media_id" to mediaId,
            "source_url" to sourceUrl,
            "title" to title,
            "creator" to author?.let { text(it, "nickname") },
            "platform" to "Douyin",
            "duration_seconds" to positiveInt(video, "duration")?.div(1000),
            "thumbnail_url" to coverUrl,
            "options" to options,
            "warnings" to listOf("不读取或发送你的登录 Cookie；匿名分享页可能使用站点临时 Cookie。"),
        )
    }

    private fun firstHttpUrl(values: JSONArray?): String? {
        if (values == null) return null
        for (index in 0 until values.length()) {
            val value = values.optString(index).trim()
            if (value.startsWith("http://") || value.startsWith("https://")) return value
        }
        return null
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
                headers = safeHttpHeaders(item.optJSONObject("http_headers")),
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
            specs[id] = LocalOption(
                "image",
                extension,
                directUrl = direct,
                headers = safeHttpHeaders(item.optJSONObject("http_headers")),
            )
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
        specs[id] = LocalOption(
            kind,
            extension,
            directUrl = direct,
            headers = safeHttpHeaders(info.optJSONObject("http_headers")),
        )
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
        destination: String,
    ): Map<String, Any?> {
        ensureEngine()
        val media = resolved[mediaId] ?: error("解析结果已过期，请重新解析链接")
        val option = media.options[optionId] ?: error("所选格式不存在，请重新解析")
        val taskDir = File(cacheDir, "local-media/$processId")
        taskDir.deleteRecursively()
        taskDir.mkdirs()
        progressState[processId] = ProgressState()
        try {
            checkNotCancelled(processId)
            val output = if (option.directUrl != null) {
                downloadDirect(option, media.title, taskDir, processId)
            } else {
                downloadWithYtDlp(media, option, taskDir, processId)
            }
            checkNotCancelled(processId)
            require(output.length() <= MAX_DOWNLOAD_BYTES) { "最终文件超过 8 GB 安全上限" }
            val published = if (destination == "gallery") {
                require(option.kind == "image" || option.kind == "video") {
                    "只有图片和视频可以保存到相册"
                }
                publishToGallery(output, option.kind)
            } else {
                publishToDownloads(output)
            }
            emitProgress(processId, 100.0, 0, "下载完成", force = true)
            return mapOf(
                "filename" to published.name,
                "path" to published.location,
                "message" to if (destination == "gallery") {
                    "已保存到系统相册"
                } else {
                    "已保存到 Download/langbai解析/${published.name}"
                },
            )
        } catch (error: Throwable) {
            if (processId in cancelledProcesses) throw DownloadCancelledException()
            throw error
        } finally {
            activeConnections.remove(processId)?.disconnect()
            cancelledProcesses.remove(processId)
            progressState.remove(processId)
            taskDir.deleteRecursively()
        }
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
        option.headers.forEach { (name, value) ->
            request.addOption("--add-header", "$name:$value")
        }
        request.addOption("--max-filesize", MAX_DOWNLOAD_BYTES.toString())
        if (option.kind == "audio") {
            request
                .addOption("--extract-audio")
                .addOption("--audio-format", option.extension)
                .addOption("--audio-quality", option.audioQuality ?: "0")
        }
        engineLock.read {
            withBilibiliCookieFile(media.bilibiliCookie) { cookieFile ->
                cookieFile?.let { request.addOption("--cookies", it.absolutePath) }
                YoutubeDL.getInstance().execute(request, processId) { progress, eta, line ->
                    emitProgress(processId, progress.toDouble(), eta, line)
                }
            }
        }
        return taskDir.walkTopDown()
            .filter { it.isFile && !it.name.endsWith(".part") && !it.name.endsWith(".ytdl") }
            .maxByOrNull { it.length() }
            ?: error("下载完成但没有找到输出文件")
    }

    private fun downloadDirect(
        option: LocalOption,
        title: String,
        taskDir: File,
        processId: String,
    ): File {
        val directUrl = option.directUrl ?: error("媒体直链不存在")
        val extension = option.extension.ifBlank { extensionFromUrl(directUrl, "bin") }
        val target = File(taskDir, "${safeFilename(title)}.$extension")
        val connection = URL(directUrl).openConnection() as HttpURLConnection
        activeConnections[processId] = connection
        connection.instanceFollowRedirects = true
        connection.connectTimeout = 20_000
        connection.readTimeout = 45_000
        val headers = option.headers.toMutableMap()
        headers.putIfAbsent(
            "User-Agent",
            "Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 Chrome/124 Mobile Safari/537.36",
        )
        headers.forEach(connection::setRequestProperty)
        try {
            checkNotCancelled(processId)
            connection.connect()
            require(connection.responseCode in 200..299) { "媒体服务器返回 ${connection.responseCode}" }
            val total = connection.contentLengthLong
            require(total <= 0 || total <= MAX_DOWNLOAD_BYTES) { "文件超过 8 GB 安全上限" }
            connection.inputStream.use { input ->
                FileOutputStream(target).use { output ->
                    val buffer = ByteArray(64 * 1024)
                    var downloaded = 0L
                    while (true) {
                        checkNotCancelled(processId)
                        val count = input.read(buffer)
                        if (count < 0) break
                        output.write(buffer, 0, count)
                        downloaded += count
                        require(downloaded <= MAX_DOWNLOAD_BYTES) { "文件超过 8 GB 安全上限" }
                        val progress = if (total > 0) downloaded * 100.0 / total else 0.0
                        emitProgress(processId, progress, null, "正在下载")
                    }
                }
            }
            return target
        } catch (error: Throwable) {
            target.delete()
            throw error
        } finally {
            activeConnections.remove(processId, connection)
            connection.disconnect()
        }
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

        @Suppress("DEPRECATION")
        val base = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
        val directory = File(base, "langbai解析").apply { mkdirs() }
        val destination = uniqueFile(directory, name)
        source.copyTo(destination, overwrite = false)
        return PublishedFile(destination.name, destination.absolutePath)
    }

    private fun publishToGallery(source: File, mediaType: String): PublishedFile {
        val name = source.name.take(220)
        val directoryName = if (mediaType == "image") {
            Environment.DIRECTORY_PICTURES
        } else {
            Environment.DIRECTORY_MOVIES
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val values = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, name)
                put(MediaStore.MediaColumns.MIME_TYPE, mimeType(name))
                put(MediaStore.MediaColumns.RELATIVE_PATH, "$directoryName/langbai解析")
                put(MediaStore.MediaColumns.IS_PENDING, 1)
            }
            val collection = if (mediaType == "image") {
                MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
            } else {
                MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
            }
            val uri = contentResolver.insert(collection, values)
                ?: error("无法在系统相册中创建媒体文件")
            try {
                contentResolver.openOutputStream(uri)?.use { output ->
                    source.inputStream().use { it.copyTo(output) }
                } ?: error("无法写入系统相册")
                values.clear()
                values.put(MediaStore.MediaColumns.IS_PENDING, 0)
                contentResolver.update(uri, values, null, null)
                return PublishedFile(name, uri.toString())
            } catch (error: Throwable) {
                contentResolver.delete(uri, null, null)
                throw error
            }
        }

        @Suppress("DEPRECATION")
        val base = Environment.getExternalStoragePublicDirectory(directoryName)
        val directory = File(base, "langbai解析").apply { mkdirs() }
        val destination = uniqueFile(directory, name)
        source.copyTo(destination, overwrite = false)
        MediaScannerConnection.scanFile(
            applicationContext,
            arrayOf(destination.absolutePath),
            arrayOf(mimeType(destination.name)),
            null,
        )
        return PublishedFile(destination.name, destination.absolutePath)
    }

    private fun emitProgress(
        processId: String,
        progress: Double,
        etaSeconds: Long?,
        status: String?,
        force: Boolean = false,
    ) {
        val now = System.currentTimeMillis()
        val normalized = progress.coerceIn(0.0, 100.0)
        val state = progressState.computeIfAbsent(processId) { ProgressState() }
        synchronized(state) {
            if (
                !force &&
                normalized < 100.0 &&
                normalized - state.progress < 1.0 &&
                now - state.timestamp < 500
            ) {
                return
            }
            state.progress = normalized
            state.timestamp = now
        }
        mainHandler.post {
            channel.invokeMethod(
                "downloadProgress",
                mapOf(
                    "process_id" to processId,
                    "progress" to normalized,
                    "eta_seconds" to etaSeconds,
                    "status" to status,
                ),
            )
        }
    }

    private fun checkNotCancelled(processId: String) {
        if (processId in cancelledProcesses || Thread.currentThread().isInterrupted) {
            throw DownloadCancelledException()
        }
    }

    private fun readLimitedHtml(input: InputStream): String {
        val output = ByteArrayOutputStream()
        val buffer = ByteArray(64 * 1024)
        var total = 0
        while (true) {
            val count = input.read(buffer)
            if (count < 0) break
            total += count
            require(total <= MAX_HTML_BYTES) { "页面响应体超过 8 MB 安全上限" }
            output.write(buffer, 0, count)
        }
        return output.toString(Charsets.UTF_8.name())
    }

    private fun safeHttpHeaders(value: JSONObject?): Map<String, String> {
        if (value == null) return emptyMap()
        val result = linkedMapOf<String, String>()
        val keys = value.keys()
        while (keys.hasNext()) {
            val rawName = keys.next()
            val name = SAFE_HEADER_NAMES.firstOrNull { it.equals(rawName, ignoreCase = true) }
                ?: continue
            val headerValue = value.optString(rawName).trim()
            if (headerValue.isNotEmpty() && '\r' !in headerValue && '\n' !in headerValue) {
                result[name] = headerValue.take(2048)
            }
        }
        return result
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
                return if (unit == "B") "${size.toLong()} B" else String.format(Locale.ROOT, "%.1f %s", size, unit)
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
        "jpg", "jpeg" -> "image/jpeg"
        "webp" -> "image/webp"
        "gif" -> "image/gif"
        "heic", "heif" -> "image/heic"
        "avif" -> "image/avif"
        else -> "application/octet-stream"
    }

    private fun kindLabel(kind: String): String = when (kind) {
        "audio" -> "音频"
        "image" -> "图片"
        else -> "视频"
    }

    private fun friendlyMessage(error: Throwable): String {
        if (
            error is DownloadCancelledException ||
            generateSequence(error) { it.cause }.any {
                it.javaClass.simpleName.contains("CanceledException", ignoreCase = true)
            }
        ) {
            return "下载已取消"
        }
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
        val lower = useful.lowercase()
        if (
            "fresh cookies" in lower ||
            "cookies (not necessarily logged in) are needed" in lower ||
            "cookies are needed" in lower ||
            "cookies are required" in lower ||
            "sign in to confirm you're not a bot" in lower ||
            "sign in to confirm you’re not a bot" in lower ||
            "use --cookies-from-browser or --cookies" in lower
        ) {
            return "该平台当前没有可用的匿名公开解析入口；langbai解析不会读取 Cookie"
        }
        if ("ip address is blocked" in lower) {
            return "当前网络出口被该平台限制，请切换网络后重试"
        }
        if ("impersonate targets are available" in lower) {
            return "该平台需要浏览器模拟组件，当前手机本地解析器暂不支持"
        }
        if ("phantomjs not found" in lower) {
            return "斗鱼当前解析接口需要额外浏览器组件，手机本地解析暂不支持"
        }
        return useful.take(500).ifEmpty { "本地解析失败，请更新解析器后重试" }
    }

    private data class LocalMedia(
        val sourceUrl: String,
        val title: String,
        val options: Map<String, LocalOption>,
        val bilibiliCookie: String? = null,
    )

    private data class LocalOption(
        val kind: String,
        val extension: String,
        val selector: String? = null,
        val audioQuality: String? = null,
        val directUrl: String? = null,
        val headers: Map<String, String> = emptyMap(),
    )

    private data class PendingStoragePermission(
        val result: MethodChannel.Result,
        val action: () -> Unit,
    )

    private data class ProgressState(
        var progress: Double = -1.0,
        var timestamp: Long = 0,
    )

    private class DownloadCancelledException : RuntimeException("下载已取消")

    private data class AudioPreset(
        val id: String,
        val label: String,
        val extension: String,
        val quality: String,
    )

    private data class PublishedFile(val name: String, val location: String)

    companion object {
        private const val STORAGE_PERMISSION_REQUEST = 1708
        private const val MAX_HTML_BYTES = 8 * 1024 * 1024
        private const val MAX_DOWNLOAD_BYTES = 8L * 1024 * 1024 * 1024
        private const val DOUYIN_MOBILE_USER_AGENT =
            "Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 Chrome/124.0 Mobile Safari/537.36"
        private const val KUAISHOU_MOBILE_USER_AGENT =
            "Mozilla/5.0 (Linux; Android 13; Pixel 7 Pro) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36"
        private val KUAISHOU_HOSTS = setOf("kuaishou.com", "chenzhongtech.com", "gifshow.com")
        private val IMAGE_EXTENSIONS = setOf("jpg", "jpeg", "png", "webp", "avif", "gif")
        private val AUDIO_EXTENSIONS = setOf("mp3", "m4a", "aac", "ogg", "opus", "wav", "flac")
        private val BILIBILI_COOKIE_NAMES = setOf(
            "SESSDATA",
            "bili_jct",
            "DedeUserID",
            "DedeUserID__ckMd5",
            "sid",
            "bili_ticket",
            "bili_ticket_expires",
        )
        private val SAFE_HEADER_NAMES = setOf(
            "User-Agent",
            "Referer",
            "Origin",
            "Accept",
            "Accept-Language",
            "Range",
        )
    }
}
