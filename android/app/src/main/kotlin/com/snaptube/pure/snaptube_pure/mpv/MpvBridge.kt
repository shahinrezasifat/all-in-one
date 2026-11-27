package com.snaptube.pure.snaptube_pure.mpv

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.view.View
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import `is`.xyz.mpv.MPVLib
import `is`.xyz.mpv.MPVNode
import java.io.File

/**
 * Flutter <-> libmpv bridge.
 *
 * The libmpv surface is hosted as a platform view; everything else (load,
 * play, seek, tracks, options) goes through a MethodChannel and property
 * changes are streamed back over an EventChannel.
 */
object MpvBridge {
    private const val METHOD_CHANNEL = "snaptube_pure/mpv"
    private const val EVENT_CHANNEL = "snaptube_pure/mpv_events"
    const val VIEW_TYPE = "snaptube_pure/mpv_view"

    private const val DEFAULT_UA =
        "Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) " +
            "Chrome/120.0.0.0 Mobile Safari/537.36"

    private val mainHandler = Handler(Looper.getMainLooper())
    private var eventSink: EventChannel.EventSink? = null
    private var activeView: MpvPlayerView? = null
    private var observerAdded = false
    private var registered = false
    private var lastPositionEmit = 0L

    private val observer = object : MPVLib.EventObserver {
        override fun eventProperty(property: String) = emit(property, null)
        override fun eventProperty(property: String, value: Long) = emit(property, value)
        override fun eventProperty(property: String, value: Boolean) = emit(property, value)
        override fun eventProperty(property: String, value: String) = emit(property, value)
        override fun eventProperty(property: String, value: Double) = emit(property, value)
        override fun eventProperty(property: String, value: MPVNode) = emit(property, value.toJson())

        override fun event(eventId: Int, data: MPVNode) {
            send(
                mapOf(
                    "type" to "event",
                    "name" to "mpvEvent",
                    "id" to eventId,
                    "value" to try {
                        data.toJson()
                    } catch (_: Exception) {
                        null
                    },
                ),
            )
        }
    }

    /** Called once from MainActivity.configureFlutterEngine. */
    fun register(flutterEngine: FlutterEngine, context: Context) {
        if (registered) return
        registered = true
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        MethodChannel(messenger, METHOD_CHANNEL).setMethodCallHandler { call, result ->
            try {
                handle(call, result)
            } catch (error: Exception) {
                result.error("mpv", error.message, error.toString())
            }
        }
        EventChannel(messenger, EVENT_CHANNEL).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    eventSink = events
                }

                override fun onCancel(arguments: Any?) {
                    eventSink = null
                }
            },
        )
        flutterEngine.platformViewsController.registry.registerViewFactory(
            VIEW_TYPE,
            object : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
                override fun create(context: Context, viewId: Int, args: Any?): PlatformView =
                    MpvPlatformView(context, viewId, args)
            },
        )
    }

    private fun emit(name: String, value: Any?) {
        if (name == "time-pos") {
            val now = System.currentTimeMillis()
            if (now - lastPositionEmit < 200) return
            lastPositionEmit = now
        }
        send(mapOf("type" to "property", "name" to name, "value" to value))
    }

    private fun send(event: Map<String, Any?>) {
        val sink = eventSink ?: return
        mainHandler.post {
            try {
                sink.success(event)
            } catch (_: Exception) {
                // The Dart listener was torn down while the event was in flight.
            }
        }
    }

    private class MpvPlatformView(
        private val context: Context,
        private val viewId: Int,
        private val args: Any?,
    ) : PlatformView {
        private val view = MpvPlayerView(context)

        init {
            // A stale view from a previous engine (hot restart) can still be
            // around. Tear it down before creating the new global MPVLib
            // instance; otherwise mpv reports "already initialized" and a
            // later double-destroy aborts the process (SIGABRT in FORTIFY).
            val previous = activeView
            if (previous != null && previous !== view) {
                previous.safeDestroy()
                if (observerAdded) {
                    MPVLib.removeObserver(observer)
                    observerAdded = false
                }
                activeView = null
            }
            val configDir = File(context.filesDir, "mpv").apply { mkdirs() }
            val cacheDir = File(context.cacheDir, "mpv").apply { mkdirs() }
            view.initialize(configDir.absolutePath, cacheDir.absolutePath)
            // Creation params carry the active Flutter theme so subtitle
            // colours change with light/dark/system mode instead of being a
            // fixed black box baked into the native player.
            val params = args as? Map<*, *>
            listOf("sub-back-color" to "subBackColor", "sub-color" to "subColor")
                .forEach { (option, key) ->
                    val color = params?.get(key) as? String
                    if (!color.isNullOrEmpty()) {
                        MPVLib.setOptionString(option, color)
                    }
                }
            activeView = view
            if (!observerAdded) {
                MPVLib.addObserver(observer)
                observerAdded = true
            }
        }

        override fun getView(): View = view

        override fun dispose() {
            val owned = activeView === view
            if (owned) {
                activeView = null
                if (observerAdded) {
                    MPVLib.removeObserver(observer)
                    observerAdded = false
                }
            }
            // Never tear down an MPVLib instance that belongs to a newer view.
            try {
                view.safeDestroy()
            } catch (_: Exception) {
            }
        }
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "isReady" -> result.success(activeView != null)
            "getState" -> result.success(state())
            "getTracks" -> result.success(
                try {
                    MPVLib.getPropertyNode("track-list")?.toJson() ?: "[]"
                } catch (_: Exception) {
                    "[]"
                },
            )

            "load" -> {
                val path = call.argument<String>("path")
                if (path.isNullOrBlank()) {
                    result.error("bad_args", "path is required", null)
                    return
                }
                val headers = call.argument<Map<String, String>>("headers").orEmpty()
                val position = call.argument<Number>("position")?.toDouble() ?: 0.0
                val isLive = call.argument<Boolean>("isLive") == true

                val fields = headers
                    .filterKeys { it.isNotBlank() }
                    .map { "${it.key}: ${it.value}" }
                    .joinToString(",")
                MPVLib.setOptionString("http-header-fields", fields)
                val ua = headers["User-Agent"] ?: headers["user-agent"] ?: DEFAULT_UA
                MPVLib.setOptionString("http-user-agent", ua)

                if (isLive) {
                    MPVLib.setOptionString("cache", "yes")
                    MPVLib.setOptionString("cache-secs", "10")
                    MPVLib.setOptionString("start", "0")
                } else {
                    MPVLib.setOptionString("cache", "auto")
                    MPVLib.setOptionString("start", if (position > 0) position.toString() else "0")
                }
                MPVLib.setPropertyBoolean("pause", false)
                MPVLib.command("loadfile", path, "replace")
                result.success(true)
            }

            "play" -> {
                MPVLib.setPropertyBoolean("pause", false)
                result.success(true)
            }

            "pause" -> {
                MPVLib.setPropertyBoolean("pause", true)
                result.success(true)
            }

            "togglePause" -> {
                val paused = MPVLib.getPropertyBoolean("pause") == true
                MPVLib.setPropertyBoolean("pause", !paused)
                result.success(!paused)
            }

            "seek" -> {
                val seconds = call.argument<Number>("seconds")?.toDouble()
                if (seconds == null) {
                    result.error("bad_args", "seconds is required", null)
                    return
                }
                val absolute = call.argument<Boolean>("absolute") != false
                val mode = if (absolute) "absolute+exact" else "relative+exact"
                MPVLib.command("seek", seconds.toString(), mode)
                result.success(true)
            }

            "setSpeed" -> {
                val speed = call.argument<Number>("speed")?.toDouble()
                if (speed == null) {
                    result.error("bad_args", "speed is required", null)
                    return
                }
                MPVLib.setPropertyDouble("speed", speed.coerceIn(0.25, 4.0))
                result.success(true)
            }

            "setVolume" -> {
                val volume = call.argument<Number>("volume")?.toDouble()
                if (volume == null) {
                    result.error("bad_args", "volume is required", null)
                    return
                }
                MPVLib.setPropertyInt("volume", (volume.coerceIn(0.0, 1.5) * 100).toInt())
                result.success(true)
            }

            "selectTrack" -> {
                val type = call.argument<String>("type")
                val id = call.argument<Number>("id")?.toInt()
                if (type == null || id == null) {
                    result.error("bad_args", "type and id are required", null)
                    return
                }
                val property = when (type) {
                    "audio" -> "aid"
                    "subtitle" -> "sid"
                    "video" -> "vid"
                    else -> {
                        result.error("bad_args", "unknown track type", null)
                        return
                    }
                }
                MPVLib.setPropertyInt(property, id)
                result.success(true)
            }

            "setOption" -> {
                val name = call.argument<String>("name")
                val value = call.argument<String>("value")
                if (name == null || value == null) {
                    result.error("bad_args", "name and value are required", null)
                    return
                }
                MPVLib.setOptionString(name, value)
                result.success(true)
            }

            "screenshot" -> {
                MPVLib.command("screenshot", "video")
                result.success(true)
            }

            else -> result.notImplemented()
        }
    }

    private fun state(): Map<String, Any> = mapOf(
        "position" to (try {
            MPVLib.getPropertyDouble("time-pos") ?: 0.0
        } catch (_: Exception) {
            0.0
        }),
        "duration" to (try {
            MPVLib.getPropertyDouble("duration") ?: 0.0
        } catch (_: Exception) {
            0.0
        }),
        "playing" to (try {
            MPVLib.getPropertyBoolean("pause") != true
        } catch (_: Exception) {
            false
        }),
        "pausedForCache" to (try {
            MPVLib.getPropertyBoolean("paused-for-cache") == true
        } catch (_: Exception) {
            false
        }),
        "seeking" to (try {
            MPVLib.getPropertyBoolean("seeking") == true
        } catch (_: Exception) {
            false
        }),
        "eof" to (try {
            MPVLib.getPropertyBoolean("eof-reached") == true
        } catch (_: Exception) {
            false
        }),
        "speed" to (try {
            MPVLib.getPropertyDouble("speed") ?: 1.0
        } catch (_: Exception) {
            1.0
        }),
        "volume" to (try {
            (MPVLib.getPropertyInt("volume") ?: 100).toDouble() / 100.0
        } catch (_: Exception) {
            1.0
        }),
        "width" to (try {
            MPVLib.getPropertyInt("width") ?: 0
        } catch (_: Exception) {
            0
        }),
        "height" to (try {
            MPVLib.getPropertyInt("height") ?: 0
        } catch (_: Exception) {
            0
        }),
        "aspect" to (try {
            MPVLib.getPropertyDouble("video-params/aspect") ?: 0.0
        } catch (_: Exception) {
            0.0
        }),
        "tracks" to (try {
            MPVLib.getPropertyNode("track-list")?.toJson() ?: "[]"
        } catch (_: Exception) {
            "[]"
        }),
    )
}
