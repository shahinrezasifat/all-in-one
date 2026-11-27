package com.snaptube.pure.snaptube_pure.mpv

import android.content.Context
import java.io.File
import `is`.xyz.mpv.BaseMPVView
import `is`.xyz.mpv.MPVLib
import `is`.xyz.mpv.MPVLib.MpvFormat

/**
 * The libmpv video surface.
 *
 * This is the same engine mpvExtended (mpvEx) uses: its JNI bridge is the
 * `io.github.marlboro-advance:mpv-android` AAR. The option set below is the
 * mobile-safe subset of mpvEx's own `MPVView.initOptions()` — hardware
 * decoding with a software fallback, bounded demuxer caches, precise seeking
 * and TLS verification — with all app-specific preference/Koin code removed.
 */
class MpvPlayerView(context: Context) :
    BaseMPVView(context, context.resources.getLayout(android.R.layout.simple_list_item_1)) {

    override fun initOptions() {
        // Copy the AAR's CA bundle so https streams (HLS CDNs, etc.) verify.
        val cert = File(context.filesDir, "cacert.pem")
        if (!cert.exists()) {
            try {
                context.assets.open("cacert.pem").use { input ->
                    cert.outputStream().use { output -> input.copyTo(output) }
                }
            } catch (_: Exception) {
                // Without the bundle https still works on most devices; never
                // crash the player just because the asset could not be copied.
            }
        }

        // Video output + hardware decoding with automatic software fallback
        // (identical priority order to mpvEx).
        setVo("gpu")
        MPVLib.setOptionString("hwdec", "mediacodec,mediacodec-copy,no")
        MPVLib.setOptionString("hwdec-codecs", "all")
        MPVLib.setOptionString("vd-lavc-film-grain", "cpu")

        // Mobile demuxer caches: 64 MiB on modern Android, 32 MiB on older.
        val cacheMegs = if (android.os.Build.VERSION.SDK_INT >=
            android.os.Build.VERSION_CODES.O_MR1
        ) 64 else 32
        MPVLib.setOptionString("demuxer-max-bytes", "${cacheMegs * 1024 * 1024}")
        MPVLib.setOptionString("demuxer-max-back-bytes", "${cacheMegs * 1024 * 1024}")

        // Precise seeks, quiet log, no built-in key bindings (Flutter owns them).
        MPVLib.setOptionString("hr-seek", "yes")
        MPVLib.setOptionString("hr-seek-framedrop", "no")
        MPVLib.setOptionString("msg-level", "all=warn")
        MPVLib.setOptionString("input-default-bindings", "no")
        MPVLib.setOptionString("speed", "1.0")
        MPVLib.setOptionString("volume-max", "150")

        // Keep the window alive at EOF so switching episode/server never shows
        // a black frame between files.
        MPVLib.setPropertyBoolean("keep-open", true)

        MPVLib.setOptionString("tls-verify", "yes")
        if (cert.exists()) MPVLib.setOptionString("tls-ca-file", cert.absolutePath)

        // Subtitles: mpv handles them natively, no external renderer needed.
        MPVLib.setOptionString("sub-auto", "exact")
        MPVLib.setOptionString("sub-font-size", "48")
        // Subtitle colours are supplied by Flutter through the platform-view
        // creation params (see MpvBridge) so they follow the app theme.
    }

    override fun postInitOptions() {
        // Nothing else is required for playback; mpvEx's shader/stat panels are
        // deliberately omitted — this player is driven from Flutter.
    }

    override fun observeProperties() {
        val props = arrayOf(
            "pause" to MpvFormat.MPV_FORMAT_FLAG,
            "paused-for-cache" to MpvFormat.MPV_FORMAT_FLAG,
            "seeking" to MpvFormat.MPV_FORMAT_FLAG,
            "eof-reached" to MpvFormat.MPV_FORMAT_FLAG,
            "time-pos" to MpvFormat.MPV_FORMAT_DOUBLE,
            "duration" to MpvFormat.MPV_FORMAT_DOUBLE,
            "speed" to MpvFormat.MPV_FORMAT_DOUBLE,
            "volume" to MpvFormat.MPV_FORMAT_INT64,
            "width" to MpvFormat.MPV_FORMAT_INT64,
            "height" to MpvFormat.MPV_FORMAT_INT64,
            "video-params/aspect" to MpvFormat.MPV_FORMAT_DOUBLE,
            "video-params/rotate" to MpvFormat.MPV_FORMAT_INT64,
            "track-list" to MpvFormat.MPV_FORMAT_NODE,
        )
        for ((name, format) in props) MPVLib.observeProperty(name, format)
    }
}
