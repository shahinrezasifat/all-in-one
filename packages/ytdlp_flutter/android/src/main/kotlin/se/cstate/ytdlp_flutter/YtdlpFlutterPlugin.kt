package se.cstate.ytdlp_flutter

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.yausername.ffmpeg.FFmpeg
import com.yausername.youtubedl_android.YoutubeDL
import com.yausername.youtubedl_android.YoutubeDLRequest
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import java.io.File
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * Android backend: wraps youtubedl-android (bundled Python + runtime-updatable
 * yt-dlp + FFmpeg). All engine calls run on a thread pool; results and
 * progress events are posted back on the main thread.
 */
class YtdlpFlutterPlugin : FlutterPlugin, MethodCallHandler {
    private lateinit var channel: MethodChannel
    private lateinit var progressChannel: EventChannel
    private lateinit var context: Context

    private val executor: ExecutorService = Executors.newCachedThreadPool()
    private val mainHandler = Handler(Looper.getMainLooper())
    private var progressSink: EventChannel.EventSink? = null

    @Volatile
    private var initialized = false

    @Volatile
    private var lastUpdateStatus: String = "not-attempted"

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "ytdlp_flutter")
        channel.setMethodCallHandler(this)
        progressChannel = EventChannel(binding.binaryMessenger, "ytdlp_flutter/progress")
        progressChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                progressSink = events
            }

            override fun onCancel(arguments: Any?) {
                progressSink = null
            }
        })
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        progressChannel.setStreamHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "init" -> runAsync(result) {
                ensureInit()
                null
            }
            "getVideoInfo" -> {
                val url = call.argument<String>("url")
                    ?: return result.error("BAD_ARGS", "url is required", null)
                runAsync(result) {
                    ensureInit()
                    val request = mediaRequest(url).apply {
                        addOption("--dump-single-json")
                        addOption("--no-playlist")
                    }
                    YoutubeDL.getInstance().execute(request).out.trim()
                }
            }
            "downloadAudio" -> {
                val url = call.argument<String>("url")
                    ?: return result.error("BAD_ARGS", "url is required", null)
                val outputDir = call.argument<String>("outputDir")
                    ?: return result.error("BAD_ARGS", "outputDir is required", null)
                val taskId = call.argument<String>("taskId")
                    ?: return result.error("BAD_ARGS", "taskId is required", null)
                val format = call.argument<String>("format") ?: "bestaudio/best"
                val audioFormat = call.argument<String>("audioFormat")
                val headers = call.argument<Map<String, String>>("headers").orEmpty()
                runAsync(result) {
                    ensureInit()
                    downloadAudio(url, outputDir, taskId, format, audioFormat, headers)
                }
            }
            "cancel" -> {
                val taskId = call.argument<String>("taskId")
                    ?: return result.error("BAD_ARGS", "taskId is required", null)
                result.success(YoutubeDL.getInstance().destroyProcessById(taskId))
            }
            "update" -> runAsync(result) {
                ensureInit()
                val status = YoutubeDL.getInstance()
                    .updateYoutubeDL(context, YoutubeDL.UpdateChannel.STABLE)
                status?.name ?: "unknown"
            }
            else -> result.notImplemented()
        }
    }

    @Synchronized
    private fun ensureInit() {
        if (initialized) return
        YoutubeDL.getInstance().init(context)
        FFmpeg.getInstance().init(context)
        // The library's bundled yt-dlp is frozen at its build date, and a
        // stale extractor is the #1 failure mode (YouTube 403s it within
        // months). Update in place — a no-op when already current, and
        // never fatal: offline devices proceed with the installed version.
        try {
            val status = YoutubeDL.getInstance()
                .updateYoutubeDL(context, YoutubeDL.UpdateChannel.STABLE)
            lastUpdateStatus = status?.name ?: "unknown"
            Log.i("ytdlp_flutter", "yt-dlp update: $lastUpdateStatus")
        } catch (e: Exception) {
            lastUpdateStatus = "failed: ${e.message}"
            Log.w("ytdlp_flutter", "yt-dlp update failed (continuing): ${e.message}")
        }
        initialized = true
    }

    /// Version + update status, appended to every error so failures on
    /// user devices are self-describing.
    private fun engineInfo(): String {
        val version = try {
            YoutubeDL.getInstance().version(context) ?: "unknown"
        } catch (e: Exception) {
            "unknown"
        }
        return "yt-dlp=$version, update=$lastUpdateStatus"
    }

    private fun mediaRequest(url: String) = YoutubeDLRequest(url).apply {
        addOption("--socket-timeout", "20")
        // youtubedl-android already sets the path to its bundled QuickJS.
        addOption("--remote-components", "ejs:github")
    }

    private fun downloadAudio(
        url: String,
        outputDir: String,
        taskId: String,
        format: String,
        audioFormat: String?,
        headers: Map<String, String>,
    ): String {
        File(outputDir).mkdirs()
        val request = mediaRequest(url).apply {
            addOption("--no-playlist")
            addOption("--downloader", "native")
            headers.forEach { (name, value) -> addCommands(listOf("--add-headers", "$name:$value")) }
            addOption("-f", format)
            addOption("--continue")
            addOption("--retries", "8")
            addOption("--fragment-retries", "8")
            addOption("--abort-on-unavailable-fragments")
            if (audioFormat != null) {
                addOption("-x")
                addOption("--audio-format", audioFormat)
            }
            addOption("-o", "$outputDir/%(id)s.%(ext)s")
            addOption("--no-simulate")
            addOption("--progress")
            addOption("--newline")
            addOption("--progress-delta", "0.25")
            addOption("--progress-template",
                "download:TUB_PROGRESS %(progress.status)s %(progress.downloaded_bytes)s " +
                    "%(progress.total_bytes)s %(progress.total_bytes_estimate)s " +
                    "%(progress.speed)s %(progress.eta)s %(progress.filename)s")
            addOption("--print", "after_move:filepath")
        }
        val received = mutableMapOf<String, Long>()
        val totals = mutableMapOf<String, Long>()
        val response = YoutubeDL.getInstance().execute(request, taskId) { _, _, line ->
            if (line.startsWith("TUB_PROGRESS ")) {
                val fields = line.removePrefix("TUB_PROGRESS ").split(' ', limit = 7)
                val bytes = fields.getOrNull(1)?.toLongOrNull()
                val file = fields.getOrNull(6)
                if (bytes != null && file != null) {
                    val finished = fields[0] == "finished"
                    received[file] = bytes
                    val total = if (finished) bytes else
                        fields[2].toLongOrNull() ?: fields[3].toLongOrNull()
                    if (total != null && total > 0) totals[file] = maxOf(total, bytes)
                    val event = mapOf(
                        "taskId" to taskId,
                        "downloadedBytes" to received.values.sum(),
                        "totalBytes" to if (totals.size == received.size) totals.values.sum() else null,
                        "speedBytesPerSecond" to if (finished) null else fields[4].toDoubleOrNull(),
                        "etaSeconds" to fields[5].toLongOrNull(),
                    )
                    mainHandler.post { progressSink?.success(event) }
                }
            }
        }
        // '--print after_move:filepath' emits the finished file on stdout;
        // scan from the end past any progress noise.
        val path = response.out.lines()
            .map { it.trim() }
            .lastOrNull { it.startsWith("/") && File(it).exists() }
            ?: throw RuntimeException("yt-dlp finished but printed no file path")
        return path
    }

    private fun runAsync(result: Result, block: () -> Any?) {
        executor.execute {
            try {
                val value = block()
                mainHandler.post { result.success(value) }
            } catch (e: YoutubeDL.CanceledException) {
                mainHandler.post { result.error("CANCELLED", "cancelled", null) }
            } catch (e: Exception) {
                mainHandler.post {
                    result.error(
                        "YTDLP_ERROR",
                        e.message ?: e.javaClass.simpleName,
                        engineInfo(),
                    )
                }
            }
        }
    }
}
