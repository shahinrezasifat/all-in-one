package com.snaptube.pure.snaptube_pure

import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.hardware.biometrics.BiometricManager
import android.hardware.biometrics.BiometricPrompt
import android.os.Build
import android.os.CancellationSignal
import android.media.AudioManager
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMuxer
import android.media.MediaScannerConnection
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.view.WindowManager
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.nio.ByteBuffer
import kotlin.concurrent.thread
import kotlin.math.roundToInt

/**
 * Native stream-copy muxer.
 *
 * Downloads of adaptive (video-only) streams arrive as two separate files: the
 * video track and the companion audio track. Re-muxing them with [MediaMuxer]
 * is a pure container operation — no re-encoding, so the original resolution
 * and bitrate are preserved bit-for-bit and it is nearly instant.
 */
class MainActivity : FlutterActivity() {

    private val channelName = "snaptube_pure/media_mux"
    private val scanChannelName = "snaptube_pure/media_scan"
    private val systemUiChannelName = "snaptube_pure/system_ui"
    private var brightnessOwner: Int? = null
    private val awakeOwners = mutableSetOf<Int>()
    private var vaultAuthentication: CancellationSignal? = null

    override fun provideFlutterEngine(context: Context): FlutterEngine? =
        FlutterEngineCache.getInstance().get("main")

    // Active downloads run on the Dart engine even after the task is dismissed.
    override fun shouldDestroyEngineWithHost(): Boolean = false

    override fun onDestroy() {
        vaultAuthentication?.cancel()
        super.onDestroy()
    }
    private var mediaVolumeTarget = 0.0
    private var lastMediaVolume: Int? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        FlutterEngineCache.getInstance().put("main", flutterEngine)

        val app = applicationContext
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "snaptube_pure/background")
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "downloads" -> {
                            val intent = Intent(app, DownloadForegroundService::class.java)
                            if (call.arguments == true) ContextCompat.startForegroundService(app, intent)
                            else app.stopService(intent)
                            result.success(null)
                        }
                        "audioOpen" -> {
                            val headers = Bundle()
                            call.argument<Map<String, String>>("headers")?.forEach { (key, value) ->
                                headers.putString(key, value)
                            }
                            val intent = Intent(app, AudioPlaybackService::class.java).setAction("open")
                                .putExtra("path", call.argument<String>("path"))
                                .putExtra("title", call.argument<String>("title"))
                                .putExtra("token", call.argument<Int>("token") ?: -1)
                                .putExtra("position", call.argument<Number>("position")?.toLong() ?: 0L)
                                .putExtra("mimeType", call.argument<String>("mimeType"))
                                .putExtra("volume", call.argument<Number>("volume")?.toFloat() ?: 1f)
                                .putExtra("speed", call.argument<Number>("speed")?.toFloat() ?: 1f)
                                .putExtra("loop", call.argument<Boolean>("loop") ?: false)
                                .putExtra("play", call.argument<Boolean>("play") ?: true)
                                .putExtra("headers", headers)
                            ContextCompat.startForegroundService(app, intent)
                            result.success(null)
                        }
                        "audioState" -> result.success(AudioPlaybackService.instance?.snapshot())
                        "audioStop" -> result.success(app.stopService(Intent(app, AudioPlaybackService::class.java)))
                        "audioControl" -> {
                            val control = requireNotNull(call.argument<String>("control"))
                            val value = requireNotNull(call.argument<Number>("value"))
                            AudioPlaybackService.instance?.control(control, value)
                            result.success(null)
                        }
                        else -> result.notImplemented()
                    }
                } catch (error: Exception) {
                    result.error("background", error.message, null)
                }
            }
        CloudStreamRuntime.attach(this, flutterEngine.dartExecutor.binaryMessenger)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "snaptube_pure/playback_controls"
        ).setMethodCallHandler { call, result ->
            val owner = call.argument<Int>("owner")
            val delta = call.argument<Double>("delta")
            when (call.method) {
                "keepScreenOn" -> {
                    if (owner != null) {
                        if (call.argument<Boolean>("enabled") == true) awakeOwners.add(owner)
                        else awakeOwners.remove(owner)
                        if (awakeOwners.isEmpty()) window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        else window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    }
                    result.success(null)
                }
                "brightness" -> {
                    if (owner == null || delta == null || !delta.isFinite()) {
                        result.error("invalid_gesture", "Missing brightness gesture", null)
                        return@setMethodCallHandler
                    }
                    val attributes = window.attributes
                    val initialBrightness = attributes.screenBrightness.takeIf { it >= 0f }
                        ?: (Settings.System.getInt(contentResolver, Settings.System.SCREEN_BRIGHTNESS, 128) / 255f)
                    val brightness = (initialBrightness + delta).coerceIn(0.02, 1.0)
                    attributes.screenBrightness = brightness.toFloat()
                    window.attributes = attributes
                    brightnessOwner = owner
                    result.success(brightness)
                }
                "restoreBrightness" -> {
                    if (owner != null && brightnessOwner == owner) {
                        val attributes = window.attributes
                        attributes.screenBrightness = WindowManager.LayoutParams.BRIGHTNESS_OVERRIDE_NONE
                        window.attributes = attributes
                        brightnessOwner = null
                    }
                    result.success(null)
                }
                "volume" -> {
                    if (delta == null || !delta.isFinite()) {
                        result.error("invalid_gesture", "Missing volume gesture", null)
                        return@setMethodCallHandler
                    }
                    val audio = getSystemService(AudioManager::class.java)
                    val stream = AudioManager.STREAM_MUSIC
                    val current = audio.getStreamVolume(stream)
                    val max = audio.getStreamMaxVolume(stream)
                    if (max <= 0 || audio.isVolumeFixed) {
                        result.success(null)
                        return@setMethodCallHandler
                    }
                    if (current != lastMediaVolume || call.argument<Boolean>("first") == true) {
                        mediaVolumeTarget = current.toDouble()
                    }
                    mediaVolumeTarget = (mediaVolumeTarget + delta * max).coerceIn(0.0, max.toDouble())
                    val target = mediaVolumeTarget.roundToInt()
                    try {
                        if (target != current) audio.setStreamVolume(stream, target, 0)
                        lastMediaVolume = audio.getStreamVolume(stream)
                        result.success(lastMediaVolume!!.toDouble() / max)
                    } catch (_: SecurityException) {
                        result.success(null)
                    }
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "snaptube_pure/app_update"
        ).setMethodCallHandler { call, result ->
            if (call.method == "getInstalledVersion") {
                @Suppress("DEPRECATION")
                val info = packageManager.getPackageInfo(packageName, 0)
                result.success(info.versionName)
            } else {
                result.notImplemented()
            }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "snaptube_pure/vault_auth"
        ).setMethodCallHandler { call, result ->
            if (call.method == "authenticate") authenticateVault(result)
            else result.notImplemented()
        }

        // The app draws its own floating navigation pill. Hide the OS bottom
        // navigation / gesture handle so there is no second "shape" under it.
        // Flutter's SystemUiMode.manual is ignored on targetSdk 36+, so do it
        // natively as well (modern insets API + legacy sticky flags fallback).
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            systemUiChannelName
        ).setMethodCallHandler { call, result ->
            if (call.method == "hideNavigationBar") {
                hideNavigationBar()
                result.success(true)
            } else {
                result.notImplemented()
            }
        }

        // ── Media scanner: index a finished download (or its saved poster) ──
        // so it appears in the Gallery / file manager immediately.
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            scanChannelName
        ).setMethodCallHandler { call, result ->
            if (call.method == "scanFile") {
                val path = call.argument<String>("path")
                if (path.isNullOrBlank()) {
                    result.error("bad_args", "path is required", null)
                    return@setMethodCallHandler
                }
                try {
                    MediaScannerConnection.scanFile(
                        applicationContext,
                        arrayOf(path),
                        null
                    ) { _, _ -> }
                    result.success(true)
                } catch (e: Throwable) {
                    result.error("scan_failed", e.message, e.toString())
                }
            } else {
                result.notImplemented()
            }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            channelName
        ).setMethodCallHandler { call, result ->
            if (call.method == "durationMs") {
                val path = call.argument<String>("path")
                if (path == null) {
                    result.error("bad_args", "path is required", null)
                } else {
                    val retriever = android.media.MediaMetadataRetriever()
                    try {
                        retriever.setDataSource(path)
                        val ms = retriever
                            .extractMetadata(
                                android.media.MediaMetadataRetriever.METADATA_KEY_DURATION
                            )
                            ?.toLongOrNull()
                        Handler(Looper.getMainLooper()).post {
                            result.success(ms)
                        }
                    } catch (e: Throwable) {
                        Handler(Looper.getMainLooper()).post {
                            result.success(null)
                        }
                    } finally {
                        try {
                            retriever.release()
                        } catch (_: Throwable) {
                        }
                    }
                }
                return@setMethodCallHandler
            }
            if (call.method != "merge") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val videoPath = call.argument<String>("videoPath")
            val audioPath = call.argument<String>("audioPath")
            val outputPath = call.argument<String>("outputPath")
            val token = call.argument<String>("token") ?: outputPath
            if (videoPath == null || audioPath == null || outputPath == null) {
                result.error("bad_args", "videoPath, audioPath and outputPath are required", null)
                return@setMethodCallHandler
            }
            val muxChannel = MethodChannel(
                flutterEngine.dartExecutor.binaryMessenger,
                channelName
            )
            // MediaMuxer / MediaExtractor are file + CPU bound: keep it off the UI thread.
            thread(name = "media-mux") {
                try {
                    mergeTracks(videoPath, audioPath, outputPath) { fraction ->
                        // Live convert-slider ticks; main thread is mandatory
                        // for invoking the Dart side of a MethodChannel.
                        try {
                            Handler(Looper.getMainLooper()).post {
                                muxChannel.invokeMethod(
                                    "muxProgress",
                                    mapOf("token" to token, "progress" to fraction)
                                )
                            }
                        } catch (_: Throwable) {
                        }
                    }
                    Handler(Looper.getMainLooper()).post {
                        result.success(true)
                    }
                } catch (e: Throwable) {
                    Handler(Looper.getMainLooper()).post {
                        result.error(
                            "mux_failed",
                            e.message ?: e.javaClass.simpleName,
                            e.toString()
                        )
                    }
                }
            }
        }
    }

    private fun authenticateVault(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) {
            result.success(false)
            return
        }
        if (vaultAuthentication != null) {
            result.success(false)
            return
        }
        val cancellation = CancellationSignal()
        vaultAuthentication = cancellation
        var replied = false
        fun finish(authenticated: Boolean) {
            if (replied) return
            replied = true
            vaultAuthentication = null
            result.success(authenticated)
        }
        val builder = BiometricPrompt.Builder(this)
            .setTitle("Unlock vault")
            .setNegativeButton("Use PIN", mainExecutor) { _, _ -> finish(false) }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) builder.setConfirmationRequired(false)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            builder.setAllowedAuthenticators(BiometricManager.Authenticators.BIOMETRIC_STRONG)
        }
        builder.build().authenticate(
            cancellation,
            mainExecutor,
            object : BiometricPrompt.AuthenticationCallback() {
                override fun onAuthenticationSucceeded(outcome: BiometricPrompt.AuthenticationResult) {
                    finish(true)
                }

                override fun onAuthenticationError(code: Int, message: CharSequence) {
                    finish(false)
                }
            }
        )
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) hideNavigationBar()
    }

    private fun hideNavigationBar() {
        val decor = window.decorView
        decor.post {
            val controller = WindowInsetsControllerCompat(window, decor)
            controller.systemBarsBehavior =
                WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            controller.hide(WindowInsetsCompat.Type.navigationBars())
        }
    }

    /**
     * Copies every sample of [videoPath] and [audioPath] into one container.
     * The container is picked from the video codec: WebM for VP8/VP9/AV1,
     * MP4 for everything else (H.264/HEVC).
     */
    private fun mergeTracks(
        videoPath: String,
        audioPath: String,
        outputPath: String,
        onProgress: ((Double) -> Unit)? = null
    ) {
        val videoFile = File(videoPath)
        val audioFile = File(audioPath)
        if (!videoFile.exists() || videoFile.length() == 0L) {
            throw IllegalStateException("Video part missing: $videoPath")
        }
        if (!audioFile.exists() || audioFile.length() == 0L) {
            throw IllegalStateException("Audio part missing: $audioPath")
        }

        val outTmp = "$outputPath.part"
        File(outTmp).parentFile?.mkdirs()
        if (File(outTmp).exists()) File(outTmp).delete()

        val videoExtractor = MediaExtractor()
        val audioExtractor = MediaExtractor()
        var muxer: MediaMuxer? = null
        try {
            videoExtractor.setDataSource(videoPath)
            audioExtractor.setDataSource(audioPath)

            val videoIndex = selectTrack(videoExtractor, video = true)
                ?: throw IllegalStateException("No video track in $videoPath")
            val audioIndex = selectTrack(audioExtractor, video = false)
                ?: throw IllegalStateException("No audio track in $audioPath")

            videoExtractor.selectTrack(videoIndex)
            audioExtractor.selectTrack(audioIndex)

            val videoFormat = videoExtractor.getTrackFormat(videoIndex)
            val audioFormat = audioExtractor.getTrackFormat(audioIndex)
            val videoMime = videoFormat.getString(MediaFormat.KEY_MIME) ?: ""

            val useWebM = isWebmVideo(videoMime)
            if (useWebM && android.os.Build.VERSION.SDK_INT < 26) {
                throw IllegalStateException(
                    "WebM muxing requires Android 8.0+ (video is $videoMime)"
                )
            }

            muxer = MediaMuxer(
                outTmp,
                if (useWebM) MediaMuxer.OutputFormat.MUXER_OUTPUT_WEBM
                else MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4
            )
            val videoTrack = muxer.addTrack(videoFormat)
            val audioTrack = muxer.addTrack(audioFormat)
            muxer.start()

            // Total media duration (microseconds) of both tracks gives the
            // progress denominator; sample times are monotonic inside a track.
            val videoDurationUs =
                if (videoFormat.containsKey(MediaFormat.KEY_DURATION))
                    videoFormat.getLong(MediaFormat.KEY_DURATION) else 0L
            val audioDurationUs =
                if (audioFormat.containsKey(MediaFormat.KEY_DURATION))
                    audioFormat.getLong(MediaFormat.KEY_DURATION) else 0L
            val totalUs = maxOf(videoDurationUs, audioDurationUs, 1L)

            // Local non-null delegate: a nullable parameter cannot be
            // smart-cast inside these capture lambdas on this Kotlin version.
            val report: (Double) -> Unit = { fraction -> onProgress?.invoke(fraction) }

            var lastReport = 0L
            copySamples(videoExtractor, videoTrack, muxer, videoFormat) { info ->
                val now = System.currentTimeMillis()
                if (now - lastReport > 250) {
                    lastReport = now
                    report(
                        (info.presentationTimeUs.toDouble() / totalUs).coerceIn(0.0, 0.9)
                    )
                }
            }
            copySamples(audioExtractor, audioTrack, muxer, audioFormat) { info ->
                val now = System.currentTimeMillis()
                if (now - lastReport > 250) {
                    lastReport = now
                    val videoDone = videoDurationUs.toDouble() / totalUs
                    report(
                        (videoDone + info.presentationTimeUs.toDouble() / totalUs * 0.5)
                            .coerceIn(0.0, 0.98)
                    )
                }
            }

            muxer.stop()
            muxer.release()
            muxer = null
            report(1.0)

            val out = File(outputPath)
            if (out.exists()) out.delete()
            if (!File(outTmp).renameTo(out)) {
                throw IllegalStateException("Could not move merged file into place")
            }
        } finally {
            try {
                videoExtractor.release()
            } catch (_: Throwable) {
            }
            try {
                audioExtractor.release()
            } catch (_: Throwable) {
            }
            if (muxer != null) {
                try {
                    muxer.release()
                } catch (_: Throwable) {
                }
            }
            val leftover = File(outTmp)
            if (leftover.exists() && !File(outputPath).exists()) leftover.delete()
        }
    }

    private fun selectTrack(extractor: MediaExtractor, video: Boolean): Int? {
        val count = extractor.trackCount
        for (i in 0 until count) {
            val format = extractor.getTrackFormat(i)
            if (format.containsKey(MediaFormat.KEY_MIME)) {
                val mime = format.getString(MediaFormat.KEY_MIME)
                if (mime != null) {
                    val isVideo = mime.toString().startsWith("video/")
                    if (isVideo == video) return i
                }
            }
        }
        return null
    }

    private fun isWebmVideo(mime: String): Boolean {
        return mime.contains("vp8", ignoreCase = true) ||
               mime.contains("vp9", ignoreCase = true) ||
               mime.contains("av01", ignoreCase = true)
    }

    private fun copySamples(
        extractor: MediaExtractor,
        trackIndex: Int,
        muxer: MediaMuxer,
        format: MediaFormat,
        onSample: ((MediaCodec.BufferInfo) -> Unit)? = null
    ) {
        extractor.seekTo(0, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
        val maxInput = if (format.containsKey(MediaFormat.KEY_MAX_INPUT_SIZE)) {
            format.getInteger(MediaFormat.KEY_MAX_INPUT_SIZE)
        } else {
            0
        }
        val buffer = ByteBuffer.allocateDirect(maxOf(maxInput, 8 * 1024 * 1024))
        val info = MediaCodec.BufferInfo()

        while (true) {
            val size = extractor.readSampleData(buffer, 0)
            if (size < 0) break
            val flags = if ((extractor.sampleFlags and MediaExtractor.SAMPLE_FLAG_SYNC) != 0) {
                MediaCodec.BUFFER_FLAG_KEY_FRAME
            } else {
                0
            }
            info.set(0, size, extractor.sampleTime, flags)
            buffer.position(0)
            buffer.limit(size)
            muxer.writeSampleData(trackIndex, buffer, info)
            onSample?.invoke(info)
            buffer.clear()
            if (!extractor.advance()) break
        }
    }
}
