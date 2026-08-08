package com.langbai.mediaharbor

internal object FilenameSanitizer {
    const val MAX_FILENAME_BYTES = 220
    private const val FALLBACK_STEM = "langbai-media"
    private val invalidCharacters = Regex("[\\\\/:*?\"<>|\\u0000-\\u001F\\r\\n]+")

    fun withExtension(
        title: String,
        extension: String,
        maxBytes: Int = MAX_FILENAME_BYTES,
    ): String {
        val safeExtension = extension
            .trim()
            .trimStart('.')
            .replace(Regex("[^A-Za-z0-9]+"), "")
            .take(12)
            .ifEmpty { "bin" }
        val suffix = ".$safeExtension"
        val suffixBytes = suffix.toByteArray(Charsets.UTF_8).size
        val stem = stem(title, (maxBytes - suffixBytes).coerceAtLeast(1))
        return "$stem$suffix"
    }

    fun filename(value: String, maxBytes: Int = MAX_FILENAME_BYTES): String {
        val leaf = value.substringAfterLast('/').substringAfterLast('\\')
        val cleaned = clean(leaf)
        if (cleaned.isEmpty()) return withExtension(FALLBACK_STEM, "bin", maxBytes)
        val dot = cleaned.lastIndexOf('.')
        val hasExtension = dot in 1 until cleaned.lastIndex
        if (!hasExtension) return stem(cleaned, maxBytes)
        return withExtension(
            cleaned.substring(0, dot),
            cleaned.substring(dot + 1),
            maxBytes,
        )
    }

    fun collisionName(
        filename: String,
        index: Int,
        maxBytes: Int = MAX_FILENAME_BYTES,
    ): String {
        val cleaned = filename(filename, maxBytes)
        val dot = cleaned.lastIndexOf('.')
        val hasExtension = dot in 1 until cleaned.lastIndex
        val extension = if (hasExtension) cleaned.substring(dot + 1) else ""
        val originalStem = if (hasExtension) cleaned.substring(0, dot) else cleaned
        val marker = " ($index)"
        val markerBytes = marker.toByteArray(Charsets.UTF_8).size
        if (extension.isEmpty()) {
            val budget = (maxBytes - markerBytes).coerceAtLeast(1)
            return "${stem(originalStem, budget)}$marker"
        }
        val suffix = ".$extension"
        val suffixBytes = suffix.toByteArray(Charsets.UTF_8).size
        val stemBudget = (maxBytes - markerBytes - suffixBytes).coerceAtLeast(1)
        return "${stem(originalStem, stemBudget)}$marker$suffix"
    }

    fun stem(value: String, maxBytes: Int = MAX_FILENAME_BYTES): String {
        val cleaned = clean(value)
        val candidate = cleaned.ifEmpty { FALLBACK_STEM }
        return truncateUtf8(candidate, maxBytes)
            .trimEnd(' ', '.')
            .ifEmpty { truncateUtf8(FALLBACK_STEM, maxBytes) }
    }

    private fun clean(value: String): String = value
        .replace(invalidCharacters, "_")
        .trim()
        .trimEnd('.')

    private fun truncateUtf8(value: String, maxBytes: Int): String {
        if (maxBytes <= 0) return ""
        val builder = StringBuilder()
        var byteCount = 0
        var index = 0
        while (index < value.length) {
            val codePoint = value.codePointAt(index)
            val chunk = String(Character.toChars(codePoint))
            val chunkBytes = chunk.toByteArray(Charsets.UTF_8).size
            if (byteCount + chunkBytes > maxBytes) break
            builder.append(chunk)
            byteCount += chunkBytes
            index += Character.charCount(codePoint)
        }
        return builder.toString()
    }
}
