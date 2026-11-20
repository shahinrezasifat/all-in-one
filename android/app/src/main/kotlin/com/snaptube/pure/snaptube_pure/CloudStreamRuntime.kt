package com.snaptube.pure.snaptube_pure

import android.app.Activity
import android.content.res.AssetManager
import android.content.res.Resources
import android.util.Log
import com.lagradost.api.setContext
import com.lagradost.cloudstream3.APIHolder
import com.lagradost.cloudstream3.AnimeLoadResponse
import com.lagradost.cloudstream3.CloudStreamApp
import com.lagradost.cloudstream3.MainAPI
import com.lagradost.cloudstream3.MainPageRequest
import com.lagradost.cloudstream3.LiveStreamLoadResponse
import com.lagradost.cloudstream3.MovieLoadResponse
import com.lagradost.cloudstream3.SearchResponse
import com.lagradost.cloudstream3.TvSeriesLoadResponse
import com.lagradost.cloudstream3.plugins.BasePlugin
import com.lagradost.cloudstream3.plugins.Plugin
import com.lagradost.cloudstream3.utils.ExtractorLink
import dalvik.system.PathClassLoader
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.lang.ref.WeakReference
import java.net.URL
import java.security.MessageDigest
import java.util.concurrent.Executors
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.withTimeoutOrNull
import org.json.JSONObject

internal object CloudStreamRuntime {
    private val executor = Executors.newFixedThreadPool(4)
    private val lock = Any()
    private val plugins = mutableMapOf<String, BasePlugin>()
    private val catalogRequests = Semaphore(12)

    fun attach(activity: Activity, messenger: BinaryMessenger) {
        CloudStreamApp.setContext(activity)
        setContext(WeakReference<Any>(activity.applicationContext))
        val root = File(activity.filesDir, "cloudstream")
        MethodChannel(messenger, "snaptube_pure/cloudstream").setMethodCallHandler { call, result ->
            executor.execute {
                try {
                    val repoId = requireNotNull(call.argument<String>("repoId"))
                    val providerId = call.argument<String>("providerId")
                    val dir = File(root, digest(repoId))
                    val file = providerId?.let { File(dir, "${digest(it)}.cs3") }
                    val value = when (call.method) {
                        "install" -> synchronized(lock) {
                            requireNotNull(file)
                            install(activity, file, requireNotNull(call.argument<String>("url")))
                            null
                        }
                        "delete" -> synchronized(lock) {
                            if (file == null) {
                                dir.listFiles()?.filter { it.extension == "cs3" }?.forEach(::remove)
                                dir.delete()
                            } else {
                                remove(file)
                            }
                            null
                        }
                        "catalog" -> {
                            val apis = synchronized(lock) {
                                val packageFile = requireNotNull(file)
                                if (!packageFile.exists()) {
                                    val packageUrl = requireNotNull(call.argument<String>("packageUrl"))
                                    install(activity, packageFile, packageUrl)
                                }
                                sources(activity, packageFile)
                            }
                            val query = call.argument<String>("query").orEmpty()
                            val page = call.argument<Int>("page") ?: 1
                            val batches = runBlocking {
                                apis.map { api -> async { catalog(api, query, page) } }
                                    .awaitAll()
                            }
                            check(batches.any { it != null }) {
                                "The source failed to respond"
                            }
                            batches.filterNotNull().flatten()
                        }
                        "resolve", "episodes", "genres" -> {
                            val apis = synchronized(lock) { sources(activity, requireNotNull(file)) }
                            val apiName = call.argument<String>("apiName")
                            val api = apis.firstOrNull { it.name == apiName }
                                ?: error("Extension source is unavailable")
                            val url = requireNotNull(call.argument<String>("url"))
                            runBlocking {
                                when (call.method) {
                                    "episodes" -> episodes(api, url)
                                    "genres" -> withTimeoutOrNull(9000) {
                                        catalogRequests.withPermit { providerCall(api) { api.load(url)?.tags } }
                                    }.orEmpty()
                                    else -> resolve(api, url, call.argument<String>("episodeData"))
                                }
                            }
                        }
                        else -> {
                            activity.runOnUiThread { result.notImplemented() }
                            return@execute
                        }
                    }
                    activity.runOnUiThread { result.success(value) }
                } catch (error: Exception) {
                    activity.runOnUiThread { result.error("cloudstream", error.message, null) }
                } catch (error: LinkageError) {
                    activity.runOnUiThread {
                        result.error("cloudstream_abi", error.message, null)
                    }
                }
            }
        }
    }

    private fun digest(value: String): String =
        MessageDigest.getInstance("SHA-256")
            .digest(value.toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it) }

    private fun install(activity: Activity, file: File, url: String) {
        if (file.isFile) {
            sources(activity, file)
            return
        }
        val endpoint = URL(url)
        require(endpoint.protocol == "https") { "Extension packages require HTTPS" }
        check(file.parentFile!!.isDirectory || file.parentFile!!.mkdirs())
        val temporary = File.createTempFile("extension-", ".tmp", file.parentFile)
        try {
            val connection = endpoint.openConnection().apply {
                connectTimeout = 10000
                readTimeout = 15000
            }
            connection.getInputStream().use { input ->
                temporary.outputStream().use { output ->
                    val buffer = ByteArray(8192)
                    var total = 0L
                    while (true) {
                        val count = input.read(buffer)
                        if (count == -1) break
                        total += count
                        check(total <= 32L * 1024 * 1024) { "Extension package is too large" }
                        output.write(buffer, 0, count)
                    }
                }
            }
            check(temporary.setReadOnly() && temporary.renameTo(file))
            try {
                sources(activity, file)
            } catch (error: Throwable) {
                remove(file)
                throw error
            }
        } finally {
            temporary.delete()
        }
    }

    private fun sources(activity: Activity, file: File): List<MainAPI> {
        val key = file.nameWithoutExtension + "@" + file.parentFile!!.name
        if (key !in plugins) {
            check(file.isFile && !file.canWrite()) { "Extension package is unavailable" }
            val loader = PathClassLoader(file.absolutePath, activity.classLoader)
            val manifest = loader.getResourceAsStream("manifest.json")
                ?.bufferedReader()?.use { JSONObject(it.readText()) }
                ?: error("Extension manifest is missing")
            val plugin = loader.loadClass(manifest.getString("pluginClassName"))
                .getDeclaredConstructor().newInstance() as BasePlugin
            plugin.filename = key
            plugins[key] = plugin
            try {
                if (plugin is Plugin) {
                    if (manifest.optBoolean("requiresResources")) {
                        plugin.resources = resourcesFor(activity, file)
                    }
                    plugin.load(activity)
                } else {
                    plugin.load()
                }
                check(APIHolder.allProviders.any { it.sourcePlugin == key }) {
                    "Extension registered no movie sources"
                }
            } catch (error: Throwable) {
                // A provider may register its catalog before initializing optional UI.
                val registered = APIHolder.allProviders.any { it.sourcePlugin == key }
                if (!registered || (error !is Exception && error !is LinkageError)) {
                    unregister(key)
                    throw error
                }
                Log.w("CloudStreamRuntime", "Extension registered with a setup error", error)
            }
        }
        return APIHolder.allProviders.filter { it.sourcePlugin == key }
    }

    @Suppress("DEPRECATION")
    private fun resourcesFor(activity: Activity, file: File): Resources {
        val assets = AssetManager::class.java.getDeclaredConstructor().newInstance()
        val cookie = AssetManager::class.java.getMethod("addAssetPath", String::class.java)
            .invoke(assets, file.absolutePath) as Int
        check(cookie != 0) { "Could not load extension resources" }
        return Resources(assets, activity.resources.displayMetrics, activity.resources.configuration)
    }

    private fun unregister(key: String) {
        plugins.remove(key)?.let { runCatching { it.beforeUnload() } }
        val providers = APIHolder.allProviders
        for (api in providers.filter { it.sourcePlugin == key }) {
            providers.remove(api)
            APIHolder.removePluginMapping(api)
        }
    }

    private fun remove(file: File) {
        unregister(file.nameWithoutExtension + "@" + file.parentFile!!.name)
        check(!file.exists() || file.delete()) { "Could not delete the extension package" }
    }

    private suspend fun catalog(api: MainAPI, query: String, page: Int): List<Map<String, Any?>>? {
        if (query.isEmpty()) {
            val sections = api.mainPage.distinctBy { it.data }
            if (sections.isEmpty()) return emptyList()
            val batches = coroutineScope { sections.map { section ->
                async {
                    withTimeoutOrNull(18000) {
                        catalogRequests.withPermit {
                            providerCall(api) {
                                val request = MainPageRequest(section.name, section.data, page > 1)
                                api.getMainPage(page, request)?.items?.flatMap { group ->
                                    group.list.map { it.toCatalogRow(api, section.name, group.name) }
                                }
                            }
                        }
                    }
                }
            }.awaitAll() }
            if (batches.all { it == null }) return null
            return batches.filterNotNull().flatten()
        }
        val items = run {
            if (page > 1) {
                return withTimeoutOrNull(15000) {
                    providerCall(api) { api.search(query, page)?.items }
                }.orEmpty().map { it.toCatalogRow(api) }
            }
            withTimeoutOrNull(15000) {
                providerCall(api) { api.search(query, page)?.items }
                    ?: providerCall(api) { api.search(query) }
                    ?: providerCall(api) { api.quickSearch(query) }
            } ?: return null
        }
        return items.map { it.toCatalogRow(api) }
    }

    private fun SearchResponse.toCatalogRow(api: MainAPI, vararg sections: String): Map<String, Any?> =
        mapOf("title" to name, "url" to url, "poster" to posterUrl,
            "type" to type?.name, "apiName" to api.name, "sections" to sections.toList())

    private suspend fun <T> providerCall(api: MainAPI, call: suspend () -> T): T? {
        return try {
            call()
        } catch (error: CancellationException) {
            throw error
        } catch (error: NotImplementedError) {
            null
        } catch (error: Exception) {
            Log.w("CloudStreamRuntime", "${api.name}: ${error.javaClass.simpleName}")
            null
        } catch (error: LinkageError) {
            Log.w("CloudStreamRuntime", "${api.name}: ${error.message}")
            null
        }
    }

    private suspend fun episodes(api: MainAPI, url: String): List<Map<String, Any?>> {
        val detail = withTimeout(15000) { api.load(url) }
        val groups = when (detail) {
            is TvSeriesLoadResponse -> listOf(null to detail.episodes)
            is AnimeLoadResponse -> detail.episodes.map { it.key.name to it.value }
            else -> emptyList()
        }
        return groups.flatMap { (group, items) ->
            items.mapIndexed { index, episode ->
                mapOf("url" to episode.data, "number" to (episode.episode ?: index + 1),
                    "title" to episode.name, "season" to episode.season, "group" to group)
            }
        }
    }

    private suspend fun resolve(api: MainAPI, url: String, episodeData: String?): List<Map<String, Any?>> {
        val data = episodeData ?: defaultStreamData(api, url) ?: return emptyList()
        val links = java.util.concurrent.ConcurrentLinkedQueue<ExtractorLink>()
        withTimeoutOrNull(25000) {
            providerCall(api) { api.loadLinks(data, false, {}, { links.add(it) }) }
        }
        return links.map {
            val headers = it.headers.toMutableMap()
            if (it.referer.isNotBlank() && headers.keys.none { key -> key.equals("referer", true) }) {
                headers["Referer"] = it.referer
            }
            mapOf("url" to it.url, "name" to it.name, "quality" to it.quality,
                "hls" to it.isM3u8, "headers" to headers)
        }
    }

    private suspend fun defaultStreamData(api: MainAPI, url: String): String? {
        val detail = withTimeout(15000) { api.load(url) }
        return when (detail) {
            is MovieLoadResponse -> detail.dataUrl
            is TvSeriesLoadResponse -> detail.episodes.firstOrNull()?.data
            is AnimeLoadResponse -> detail.episodes.values.firstOrNull()?.firstOrNull()?.data
            is LiveStreamLoadResponse -> detail.dataUrl
            else -> null
        }
    }
}
