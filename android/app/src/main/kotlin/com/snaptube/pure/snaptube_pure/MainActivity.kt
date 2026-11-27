package com.snaptube.pure.snaptube_pure

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageInstaller
import android.speech.RecognizerIntent
import android.net.Uri
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Bundle
import android.os.Environment
import android.os.storage.StorageManager
import android.provider.DocumentsContract
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
import androidx.core.content.FileProvider
import androidx.core.content.pm.PackageInfoCompat
import io.flutter.plugin.common.MethodChannel
import com.snaptube.pure.snaptube_pure.mpv.MpvBridge
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
    private var pendingFolderResult: MethodChannel.Result? = null

    companion object {
        private const val REQUEST_PICK_DOWNLOAD_FOLDER = 7319
        private const val REQUEST_INSTALL_UPDATE = 7321
        private const val REQUEST_SPEECH = 7322
    }

    private var pendingInstallResult: MethodChannel.Result? = null
    private var installReceiver: BroadcastReceiver? = null
    private var pendingSpeechResult: MethodChannel.Result? = null

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == REQUEST_SPEECH) {
            val result = pendingSpeechResult
            pendingSpeechResult = null
            if (resultCode == RESULT_OK && data != null) {
                val matches = data.getStringArrayListExtra(RecognizerIntent.EXTRA_RESULTS)
                val spoken = matches?.firstOrNull()?.trim()
                if (spoken.isNullOrEmpty()) result?.success(null)
                else result?.success(spoken)
            } else {
                result?.success(null)
            }
            return
        }
        if (requestCode == REQUEST_PICK_DOWNLOAD_FOLDER) {
            val result = pendingFolderResult
            pendingFolderResult = null
            val uri = data?.data
            if (resultCode != RESULT_OK || uri == null || result == null) {
                result?.success(null)
                return
            }
            try {
                contentResolver.takePersistableUriPermission(
                    uri,
                    Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
                )
            } catch (_: SecurityException) {
            }
            result.success(
                mapOf(
                    "path" to treeUriToRawPath(uri),
                    "uri" to uri.toString()
                )
            )
            return
        }
        super.onActivityResult(requestCode, resultCode, data)
    }

    private fun treeUriToRawPath(uri: Uri): String? {
        val documentId = try {
            DocumentsContract.getTreeDocumentId(uri)
        } catch (_: IllegalArgumentException) {
            null
        } ?: return null
        val externalRoot = Environment.getExternalStorageDirectory().absolutePath
        // Some providers return "raw:/storage/emulated/0/Download/Folder"
        // instead of "primary:Download/Folder" — handle both shapes.
        if (documentId.startsWith("raw:")) {
            val raw = documentId.removePrefix("raw:").trim()
            if (raw.startsWith("/")) return File(raw).absolutePath
        }
        val separator = documentId.indexOf(':')
        if (separator <= 0) return null
        val root = documentId.substring(0, separator)
        val relative = documentId.substring(separator + 1)
            .removePrefix("/")
            .replace('/', File.separatorChar)
        val base = when (root) {
            "primary", "home" -> externalRoot
            "raw" -> externalRoot
            else -> "/storage/$root"
        }
        val candidate = File("$base/$relative".replace("//", "/")).absolutePath
        // Final sanity check: never hand Dart a path that does not exist.
        return if (File(candidate).exists()) candidate else null
    }

    private fun storageVolumes(): List<Map<String, Any>> {
        return try {
            val manager = getSystemService(StorageManager::class.java)
            manager.storageVolumes.map { volume ->
                val internal = volume.uuid == null
                val downloadPath = if (internal) {
                    Environment.getExternalStoragePublicDirectory(
                        Environment.DIRECTORY_DOWNLOADS
                    ).absolutePath
                } else {
                    "/storage/${volume.uuid}/Download"
                }
                mapOf(
                    "id" to (volume.uuid ?: "internal"),
                    "label" to (volume.getDescription(this)
                        ?: if (internal) "Internal storage" else "SD card"),
                    "downloadPath" to downloadPath
                )
            }
        } catch (_: Exception) {
            listOf(
                mapOf(
                    "id" to "internal",
                    "label" to "Internal storage",
                    "downloadPath" to Environment.getExternalStoragePublicDirectory(
                        Environment.DIRECTORY_DOWNLOADS
                    ).absolutePath
                )
            )
        }
    }

    private fun openFolder(path: String) {
        val target = File(path)
        val uri = if (target.exists() && target.isDirectory) {
            val documentId = if (path.contains("/emulated/0")) {
                "primary:${path.substringAfter("/emulated/0/").removePrefix("/")}"
            } else {
                val volume = path.removePrefix("/storage/").substringBefore("/")
                "$volume:${path.substringAfter("/storage/$volume/")}"
            }
            try {
                DocumentsContract.buildTreeDocumentUri(
                    "com.android.externalstorage.documents",
                    documentId
                )
            } catch (_: Exception) {
                FileProvider.getUriForFile(
                    this,
                    "$packageName.fileprovider",
                    target
                )
            }
        } else {
            Uri.parse(path)
        }
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "resource/folder")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        try {
            startActivity(intent)
        } catch (_: Exception) {
            // Some file managers do not declare a folder viewer; nothing else
            // to do — the settings screen shows the full path as text.
        }
    }

    override fun provideFlutterEngine(context: Context): FlutterEngine? =
        FlutterEngineCache.getInstance().get("main")

    // Active downloads run on the Dart engine even after the task is dismissed.
    override fun shouldDestroyEngineWithHost(): Boolean = false

    override fun onDestroy() {
        vaultAuthentication?.cancel()
        if (pendingInstallResult != null) {
            finishUpdateInstall("INSTALL_ERROR", "The installer was interrupted. Try again.")
        }
        super.onDestroy()
    }
    private var mediaVolumeTarget = 0.0
    private var lastMediaVolume: Int? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        FlutterEngineCache.getInstance().put("main", flutterEngine)

        // libmpv player surface + control/event channels (same engine mpvEx uses).
        MpvBridge.register(flutterEngine, applicationContext)

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
            "snaptube_pure/storage"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "listVolumes" -> result.success(storageVolumes())
                "pickFolder" -> {
                    if (pendingFolderResult != null) {
                        result.error("picker_busy", "A folder picker is already open", null)
                    } else {
                        pendingFolderResult = result
                        startActivityForResult(
                            Intent(Intent.ACTION_OPEN_DOCUMENT_TREE),
                            REQUEST_PICK_DOWNLOAD_FOLDER
                        )
                    }
                }
                "openFolder" -> {
                    val path = call.argument<String>("path")
                    if (path.isNullOrBlank()) {
                        result.error("bad_args", "path is required", null)
                    } else {
                        openFolder(path)
                        result.success(null)
                    }
                }
                else -> result.notImplemented()
            }
        }

        // Free voice input: Android's built-in speech recognizer, no API key.
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "snaptube_pure/speech"
        ).setMethodCallHandler { call, result ->
            if (call.method == "recognize") {
                if (pendingSpeechResult != null) {
                    result.success(null)
                    return@setMethodCallHandler
                }
                val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
                    putExtra(
                        RecognizerIntent.EXTRA_LANGUAGE_MODEL,
                        RecognizerIntent.LANGUAGE_MODEL_FREE_FORM
                    )
                    putExtra(RecognizerIntent.EXTRA_PROMPT, "Say what you want to search")
                    putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 1)
                }
                if (intent.resolveActivity(packageManager) == null) {
                    result.success(null)
                    return@setMethodCallHandler
                }
                pendingSpeechResult = result
                startActivityForResult(intent, REQUEST_SPEECH)
            } else {
                result.notImplemented()
            }
        }

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
            when (call.method) {
                "getInstalledVersion" -> {
                    @Suppress("DEPRECATION")
                    val info = packageManager.getPackageInfo(packageName, 0)
                    result.success(info.versionName)
                }
                "installUpdate" -> installAppUpdate(result)
                "supportedAbis" -> result.success(Build.SUPPORTED_ABIS.toList())
                "hasUpdateWifi" -> {
                    val connectivity = getSystemService(ConnectivityManager::class.java)
                    val active = connectivity?.activeNetwork
                    result.success(active != null &&
                        connectivity?.getNetworkCapabilities(active)?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true)
                }
                "openInstallSettings" -> try {
                    startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:$packageName")))
                    result.success(null)
                } catch (_: Exception) {
                    result.error("INSTALL_ERROR", "Android could not open install settings.", null)
                }
                "restartAfterUpdate" -> {
                    val launch = packageManager.getLaunchIntentForPackage(packageName)
                    if (launch != null) startActivity(launch.addFlags(Intent.FLAG_ACTIVITY_CLEAR_TASK or Intent.FLAG_ACTIVITY_NEW_TASK))
                    result.success(null)
                }
                else -> result.notImplemented()
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

    private fun canInstallUpdates(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.O || packageManager.canRequestPackageInstalls()

    private fun finishUpdateInstall(code: String? = null, message: String? = null) {
        installReceiver?.let { unregisterReceiver(it) }
        installReceiver = null
        val result = pendingInstallResult
        pendingInstallResult = null
        if (code == null) result?.success(true)
        else result?.error(code, message, null)
    }

    @Suppress("DEPRECATION")
    private fun installAppUpdate(result: MethodChannel.Result) {
        if (pendingInstallResult != null) {
            result.error("INSTALL_BUSY", "An update is already installing.", null)
            return
        }
        if (!canInstallUpdates()) {
            result.success(false)
            return
        }
        pendingInstallResult = result
        val installer = packageManager.packageInstaller
        thread(name = "stage-app-update") {
            var sessionId: Int? = null
            var unpacked: File? = null
            try {
                val apk = File(cacheDir, "app-updates/update.apk")
                val standalone = packageManager.getPackageArchiveInfo(apk.path, 0)
                val files = if (standalone != null) listOf(apk) else try {
                    val folder = File(apk.parentFile, "bundle-${java.util.UUID.randomUUID()}")
                    check(folder.mkdir())
                    unpacked = folder
                    unpackUpdateApks(apk, folder)
                } catch (_: Exception) {
                    emptyList()
                }
                val archive = standalone ?: files.firstOrNull()?.let {
                    packageManager.getPackageArchiveInfo(it.path, 0)
                }
                val installed = packageManager.getPackageInfo(packageName, 0)
                if (archive == null || archive.packageName != packageName ||
                    PackageInfoCompat.getLongVersionCode(archive) <=
                        PackageInfoCompat.getLongVersionCode(installed)
                ) {
                    runOnUiThread {
                        if (pendingInstallResult === result) {
                            finishUpdateInstall("INVALID_UPDATE", "The APK is not a newer All in One version.")
                        }
                    }
                    return@thread
                }
                val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL)
                params.setAppPackageName(packageName)
                params.setSize(files.sumOf { it.length() })
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    params.setRequireUserAction(PackageInstaller.SessionParams.USER_ACTION_REQUIRED)
                }
                val id = installer.createSession(params)
                sessionId = id
                installer.openSession(id).use { session ->
                    files.forEachIndexed { index, part ->
                        part.inputStream().use { input ->
                            session.openWrite(if (index == 0) "base.apk" else part.name, 0, part.length()).use { output ->
                                input.copyTo(output)
                                session.fsync(output)
                            }
                        }
                    }
                }
                runOnUiThread {
                    if (pendingInstallResult !== result) {
                        runCatching { installer.abandonSession(id) }
                        return@runOnUiThread
                    }
                    try {
                        val action = "$packageName.INSTALL_RESULT.$id"
                        val receiver = object : BroadcastReceiver() {
                            override fun onReceive(context: Context, intent: Intent) {
                                if (intent.action != action ||
                                    intent.getIntExtra(PackageInstaller.EXTRA_SESSION_ID, -1) != id ||
                                    pendingInstallResult !== result
                                ) return
                                when (intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)) {
                                    PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                                        val confirmation = intent.getParcelableExtra<Intent>(Intent.EXTRA_INTENT)
                                        try {
                                            checkNotNull(confirmation)
                                            startActivity(confirmation)
                                        } catch (_: Exception) {
                                            runCatching { installer.abandonSession(id) }
                                            finishUpdateInstall("INSTALL_ERROR", "Android could not open the confirmation screen.")
                                        }
                                    }
                                    PackageInstaller.STATUS_SUCCESS -> finishUpdateInstall()
                                    else -> finishUpdateInstall(
                                        "INSTALL_FAILED",
                                        intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE)
                                            ?: "The installation did not complete."
                                    )
                                }
                            }
                        }
                        ContextCompat.registerReceiver(
                            this, receiver, IntentFilter(action), ContextCompat.RECEIVER_NOT_EXPORTED
                        )
                        installReceiver = receiver
                        val pending = PendingIntent.getBroadcast(
                            this, id, Intent(action).setPackage(packageName),
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) PendingIntent.FLAG_MUTABLE else 0
                        )
                        installer.openSession(id).use { it.commit(pending.intentSender) }
                    } catch (_: Exception) {
                        runCatching { installer.abandonSession(id) }
                        finishUpdateInstall("INSTALL_ERROR", "Android could not start the installation.")
                    }
                }
            } catch (_: Exception) {
                sessionId?.let { runCatching { installer.abandonSession(it) } }
                runOnUiThread {
                    if (pendingInstallResult === result) {
                        finishUpdateInstall("INSTALL_ERROR", "Android could not prepare the update.")
                    }
                }
            } finally {
                unpacked?.deleteRecursively()
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
