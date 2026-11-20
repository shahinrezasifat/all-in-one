package com.lagradost.cloudstream3.plugins

import android.content.Context
import android.content.res.Resources

/** App-side entry point that CloudStream extensions link against. */
abstract class Plugin : BasePlugin() {
    open fun load(context: Context) = load()

    var resources: Resources? = null
    var needsResources: Boolean = false
    var openSettings: ((Context) -> Unit)? = null

    companion object {
        const val `$stable` = 8
    }
}
