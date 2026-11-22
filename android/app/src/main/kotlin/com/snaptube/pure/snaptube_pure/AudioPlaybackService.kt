package com.snaptube.pure.snaptube_pure

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.media.MediaMetadata
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.net.Uri
import android.os.Build
import android.os.IBinder
import androidx.annotation.OptIn
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import java.io.File

@OptIn(UnstableApi::class)
class AudioPlaybackService : Service() {
    companion object {
        var instance: AudioPlaybackService? = null
            private set
    }

    private lateinit var player: ExoPlayer
    private lateinit var session: MediaSession
    private var title = "Audio playback"
    private var token = -1
    private var latestError: String? = null
    private var foregrounded = false

    /** Notification actions arrive as plain startService intents; every start
     *  path must re-establish the foreground notification, especially after
     *  the process was killed and the service was recreated. */
    private fun ensureForeground() {
        if (foregrounded) return
        try {
            startForeground(4202, notification())
            foregrounded = true
        } catch (error: Exception) {
            // Foreground start can be rejected by Android 14+ restrictions;
            // playback still works and updateSession keeps the notification.
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        instance = this
        player = ExoPlayer.Builder(this)
            .setWakeMode(C.WAKE_MODE_LOCAL)
            .setAudioAttributes(AudioAttributes.DEFAULT, true)
            .setHandleAudioBecomingNoisy(true)
            .build()
        player.trackSelectionParameters = player.trackSelectionParameters.buildUpon()
            .setTrackTypeDisabled(C.TRACK_TYPE_VIDEO, true).build()
        session = MediaSession(this, "All in One audio")
        session.setSessionActivity(appPendingIntent())
        session.setCallback(object : MediaSession.Callback() {
            override fun onPlay() = control("play", 1)
            override fun onPause() = player.pause()
            override fun onSeekTo(pos: Long) = player.seekTo(pos)
            override fun onStop() { stopSelf() }
        })
        session.isActive = true
        player.addListener(object : Player.Listener {
            override fun onEvents(player: Player, events: Player.Events) {
                latestError = player.playerError?.localizedMessage ?: latestError
                updateSession()
            }
        })
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == "stop") {
            stopSelf()
            return START_NOT_STICKY
        }
        ensureForeground()
        when (intent?.action) {
            "toggle" -> control("play", if (playbackRequested()) 0 else 1)
            "open" -> {
                val path = intent.getStringExtra("path") ?: return START_NOT_STICKY
                val uri = if (path.startsWith("/") || !Uri.parse(path).isAbsolute) {
                    Uri.fromFile(File(path))
                } else Uri.parse(path)
                title = intent.getStringExtra("title") ?: "Audio playback"
                token = intent.getIntExtra("token", -1)
                latestError = null
                val headers = intent.getBundleExtra("headers")
                val http = DefaultHttpDataSource.Factory().setAllowCrossProtocolRedirects(true)
                if (headers != null) {
                    http.setDefaultRequestProperties(headers.keySet().associateWith {
                        headers.getString(it).orEmpty()
                    })
                }
                val media = MediaItem.Builder().setUri(uri)
                intent.getStringExtra("mimeType")?.let { media.setMimeType(it) }
                val source = DefaultMediaSourceFactory(DefaultDataSource.Factory(this, http))
                    .createMediaSource(media.build())
                player.setMediaSource(source, intent.getLongExtra("position", 0))
                player.volume = intent.getFloatExtra("volume", 1f)
                player.setPlaybackSpeed(intent.getFloatExtra("speed", 1f))
                player.repeatMode = if (intent.getBooleanExtra("loop", false)) {
                    Player.REPEAT_MODE_ONE
                } else Player.REPEAT_MODE_OFF
                player.playWhenReady = intent.getBooleanExtra("play", true)
                player.prepare()
                updateSession()
            }
        }
        return START_NOT_STICKY
    }

    fun control(method: String, value: Number) {
        when (method) {
            "play" -> if (value.toInt() == 1) {
                if (player.playbackState == Player.STATE_ENDED) player.seekToDefaultPosition()
                if (player.playerError != null) {
                    latestError = null
                    player.prepare()
                }
                player.play()
            } else player.pause()
            "position" -> player.seekTo(value.toLong())
            "speed" -> player.setPlaybackSpeed(value.toFloat())
            "volume" -> player.volume = value.toFloat()
            "loop" -> player.repeatMode = if (value.toInt() == 1) {
                Player.REPEAT_MODE_ONE
            } else Player.REPEAT_MODE_OFF
        }
    }

    private fun playbackRequested() =
        player.playWhenReady && player.playbackState != Player.STATE_ENDED &&
            player.playerError == null

    fun snapshot() = mapOf(
        "token" to token,
        "position" to player.currentPosition,
        "duration" to player.duration.coerceAtLeast(0L),
        "playing" to playbackRequested(),
        "buffering" to (player.playbackState == Player.STATE_BUFFERING),
        "ended" to (player.playbackState == Player.STATE_ENDED),
        "error" to latestError
    )

    private fun updateSession() {
        val status = when {
            player.playerError != null -> PlaybackState.STATE_ERROR
            player.playbackState == Player.STATE_BUFFERING -> PlaybackState.STATE_BUFFERING
            player.isPlaying -> PlaybackState.STATE_PLAYING
            else -> PlaybackState.STATE_PAUSED
        }
        session.setMetadata(MediaMetadata.Builder()
            .putString(MediaMetadata.METADATA_KEY_TITLE, title)
            .putLong(MediaMetadata.METADATA_KEY_DURATION, player.duration.coerceAtLeast(0L))
            .build())
        session.setPlaybackState(PlaybackState.Builder()
            .setActions(PlaybackState.ACTION_PLAY_PAUSE or PlaybackState.ACTION_PLAY or
                PlaybackState.ACTION_PAUSE or PlaybackState.ACTION_STOP or PlaybackState.ACTION_SEEK_TO)
            .setState(status, player.currentPosition, if (player.isPlaying) player.playbackParameters.speed else 0f)
            .build())
        val manager = getSystemService(NotificationManager::class.java)
        if (foregrounded) {
            startForeground(4202, notification())
        } else {
            manager.notify(4202, notification())
        }
    }

    private fun notification(): Notification {
        val builder = if (Build.VERSION.SDK_INT >= 26) {
            getSystemService(NotificationManager::class.java).createNotificationChannel(
                NotificationChannel("audio", "Audio playback", NotificationManager.IMPORTANCE_LOW)
            )
            Notification.Builder(this, "audio")
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        fun action(command: String, code: Int) = PendingIntent.getService(
            this, code, Intent(this, AudioPlaybackService::class.java).setAction(command),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        val playing = playbackRequested()
        return builder.setSmallIcon(android.R.drawable.ic_media_play)
            .setContentTitle(title)
            .setContentIntent(appPendingIntent())
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .setStyle(Notification.MediaStyle().setMediaSession(session.sessionToken)
                .setShowActionsInCompactView(0, 1))
            .addAction(Notification.Action.Builder(
                android.graphics.drawable.Icon.createWithResource(this,
                    if (playing) android.R.drawable.ic_media_pause else android.R.drawable.ic_media_play),
                if (playing) "Pause" else "Play", action("toggle", 1)).build())
            .addAction(Notification.Action.Builder(
                android.graphics.drawable.Icon.createWithResource(this, android.R.drawable.ic_menu_close_clear_cancel),
                "Stop", action("stop", 2)).build())
            .setOngoing(playing)
            .build()
    }

    override fun onDestroy() {
        instance = null
        player.release()
        session.release()
        super.onDestroy()
    }
}
