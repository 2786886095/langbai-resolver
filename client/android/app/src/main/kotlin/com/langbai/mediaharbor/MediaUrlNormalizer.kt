package com.langbai.mediaharbor

/** Pure helpers kept outside Activity so URL behaviour can be unit tested. */
internal object MediaUrlNormalizer {
    private val douyinWatermarkPath = Regex("/aweme/v1/playwm(?=/|\\?|$)")

    fun normalizeDouyinPlayUrl(value: String): String =
        douyinWatermarkPath.replaceFirst(value, "/aweme/v1/play")

    fun shouldExposeDouyinVideo(playUrl: String?, imageCount: Int): Boolean =
        !playUrl.isNullOrBlank() && imageCount == 0

    fun isObviousTextMediaError(
        contentType: String?,
        firstChunk: ByteArray,
        count: Int = firstChunk.size,
    ): Boolean {
        val mediaType = contentType
            ?.substringBefore(';')
            ?.trim()
            ?.lowercase()
            .orEmpty()
        val textual = mediaType.startsWith("text/") ||
            mediaType == "application/json" || mediaType.endsWith("+json") ||
            mediaType == "application/xml" || mediaType.endsWith("+xml") ||
            mediaType == "application/vnd.apple.mpegurl" ||
            mediaType == "application/x-mpegurl"
        if (textual) return true
        if (count <= 0) return false
        val prefix = firstChunk
            .decodeToString(0, count.coerceIn(0, minOf(firstChunk.size, 8192)))
            .trimStart('\uFEFF', ' ', '\t', '\r', '\n')
            .lowercase()
        return prefix.startsWith("<!doctype html") ||
            prefix.startsWith("<html") ||
            prefix.startsWith("<?xml") ||
            prefix.startsWith("{") ||
            prefix.startsWith("[") ||
            prefix.startsWith("#extm3u")
    }
}
