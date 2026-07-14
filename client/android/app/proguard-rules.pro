# yt-dlp-android initializes its runtime and FFmpeg bridge through library APIs
# that may be reached indirectly from Flutter's method channel.
-keep class com.yausername.youtubedl_android.** { *; }
-keep class com.yausername.ffmpeg.** { *; }
# Commons Compress 1.x registers ZIP extra-field implementations with
# Class.newInstance(). R8 class merging/obfuscation can turn those reflected
# concrete classes into names such as d2.a which then fail during Python
# runtime extraction with "is not a concrete class".
-keep class org.apache.commons.compress.archivers.zip.** { *; }
-keepattributes RuntimeVisibleAnnotations,RuntimeInvisibleAnnotations,AnnotationDefault
