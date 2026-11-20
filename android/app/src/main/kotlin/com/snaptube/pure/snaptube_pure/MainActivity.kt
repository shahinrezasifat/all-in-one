package com.snaptube.pure.snaptube_pure

import android.hardware.biometrics.BiometricManager
import android.hardware.biometrics.BiometricPrompt
import android.os.Build
import android.os.CancellationSignal
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMuxer
import android.media.MediaScannerConnection
import android.os.Handler
import android.os.Looper
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.nio.ByteBuffer
import kotlin.concurrent.thread

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

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        CloudStreamRuntime.attach(this, flutterEngine.dartExecutor.binaryMessenger)

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
        var replied = false
        fun finish(authenticated: Boolean) {
            if (replied) return
            replied = true
            result.success(authenticated)
        }
        val builder = BiometricPrompt.Builder(this)
            .setTitle("Secret Vault")
            .setNegativeButton("Use PIN", mainExecutor) { _, _ -> finish(false) }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            builder.setAllowedAuthenticators(BiometricManager.Authenticators.BIOMETRIC_STRONG)
        }
        builder.build().authenticate(
            CancellationSignal(),
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
