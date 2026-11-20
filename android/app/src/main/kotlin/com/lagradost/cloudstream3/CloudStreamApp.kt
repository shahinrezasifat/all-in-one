package com.lagradost.cloudstream3

import android.content.Context

/** Context accessor used by extensions compiled against the CloudStream app. */
class CloudStreamApp {
    companion object {
        @Volatile
        private var context: Context? = null

        fun setContext(value: Context) {
            context = value.applicationContext
        }

        fun getContext(): Context? = context
    }
}
