# yt-dlp-android initializes its runtime and FFmpeg bridge through library APIs
# that may be reached indirectly from Flutter's method channel.
-keep class com.yausername.youtubedl_android.** { *; }
-keep class com.yausername.ffmpeg.** { *; }
-keepattributes RuntimeVisibleAnnotations,RuntimeInvisibleAnnotations,AnnotationDefault
