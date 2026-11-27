package com.snaptube.pure.snaptube_pure.ffmpeg

import android.content.Context
import android.os.Handler
import android.os.Looper
import com.yausername.ffmpeg.FFmpeg
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import kotlin.concurrent.thread

/**
 * Runs the FFmpeg executable that youtubedl-android already ships inside the
 * APK. It is deliberately separate from the FFmpegKit JNI library: mpv's
 * libav*.so exports LIBAVCODEC_63 while FFmpegKit expects LIBAVCODEC_62, so
 * loading both in one process kills the app at startup with
 * UnsatisfiedLinkError. This executable links against the *versioned* libs
 * (libavcodec.so.61 …) that youtubedl-android extracts into its own package
 * directory, which cannot collide with mpv's unversioned libraries.
 */
object FfmpegRunner {
    private const val CHANNEL = "snaptube_pure/ffmpeg_exec"
    private val mainHandler = Handler(Looper.getMainLooper())
    private var channel: MethodChannel? = null

    fun register(flutterEngine: FlutterEngine, context: Context) {
        val app = context.applicationContext
        val methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        channel = methodChannel
        methodChannel.setMethodCallHandler { call, result ->
            if (call.method != "run") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val args = call.argument<List<String>>("args")
            if (args.isNullOrEmpty()) {
                result.error("bad_args", "args are required", null)
                return@setMethodCallHandler
            }
            val token = call.argument<String>("token") ?: args.joinToString("|")
            val durationMs = call.argument<Number>("durationMs")?.toLong() ?: 0L

            thread(name = "ffmpeg-exec-$token") {
                var process: Process? = null
                try {
                    // Idempotent: extracts libffmpeg.zip.so on first use. Doing
                    // this here keeps conversions working even when yt-dlp was
                    // never initialised (e.g. a local file conversion).
                    FFmpeg.getInstance().init(app)

                    val nativeDir = app.applicationInfo.nativeLibraryDir
                    val executable = File(nativeDir, "libffmpeg.so")
                    if (!executable.exists()) {
                        throw IllegalStateException("Bundled FFmpeg executable is missing")
                    }
                    val libraryDir = File(
                        File(File(app.noBackupFilesDir, "youtubedl-android"), "packages"),
                        "ffmpeg/usr/lib",
                    )
                    val environment = HashMap(System.getenv())
                    environment["LD_LIBRARY_PATH"] =
                        listOf(nativeDir, libraryDir.absolutePath).joinToString(File.pathSeparator)
                    environment["TMPDIR"] = app.cacheDir.absolutePath

                    val builder = ProcessBuilder(listOf(executable.absolutePath) + args)
                    builder.environment().clear()
                    builder.environment().putAll(environment)
                    builder.redirectErrorStream(false)
                    process = builder.start()

                    val errors = StringBuilder()
                    val errorReader = thread(name = "ffmpeg-stderr-$token") {
                        process!!.errorStream.bufferedReader().useLines { lines ->
                            lines.forEach { line ->
                                if (errors.length < 4000) errors.appendLine(line)
                            }
                        }
                    }

                    val durationPattern = Regex(
                        """Duration:\s*(\d+):(\d+):(\d+)\.(\d+)""",
                    )
                    var total = durationMs
                    val started = System.currentTimeMillis()
                    process!!.inputStream.bufferedReader().useLines { lines ->
                        for (line in lines) {
                            val match = durationPattern.find(line)
                            if (match != null && total <= 0) {
                                total =
                                    (match.groupValues[1].toLong() * 3600 +
                                        match.groupValues[2].toLong() * 60 +
                                        match.groupValues[3].toLong()) * 1000 +
                                        match.groupValues[4].toLong() * 10
                            }
                            if (line.startsWith("out_time_us=")) {
                                val us = line.removePrefix("out_time_us=").trim().toLongOrNull() ?: 0L
                                val progress = if (total > 0) {
                                    us / 1000.0 / total
                                } else {
                                    val elapsed = System.currentTimeMillis() - started
                                    elapsed / (elapsed + 15000.0)
                                }
                                emit(token, progress.coerceIn(0.0, 0.995))
                            } else if (line.startsWith("progress=end")) {
                                emit(token, 1.0)
                            }
                        }
                    }

                    val code = process!!.waitFor()
                    try {
                        errorReader.join(1000)
                    } catch (_: InterruptedException) {
                    }
                    if (code == 0) {
                        emit(token, 1.0)
                        mainHandler.post { result.success(true) }
                    } else {
                        val detail = errors.toString().trim().take(600)
                        mainHandler.post {
                            result.error(
                                "ffmpeg_failed",
                                if (detail.isEmpty()) "FFmpeg exited with code $code" else detail,
                                null,
                            )
                        }
                    }
                } catch (error: Throwable) {
                    mainHandler.post {
                        result.error(
                            "ffmpeg_error",
                            error.message ?: error.javaClass.simpleName,
                            error.toString(),
                        )
                    }
                } finally {
                    process?.destroy()
                }
            }
        }
    }

    private fun emit(token: String, progress: Double) {
        mainHandler.post {
            try {
                channel?.invokeMethod(
                    "ffmpegProgress",
                    mapOf("token" to token, "progress" to progress),
                )
            } catch (_: Throwable) {
                // The Dart listener may be gone while a conversion is in flight.
            }
        }
    }
}
