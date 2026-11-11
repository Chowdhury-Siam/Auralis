package com.auralis.siam

import android.app.Activity
import com.chaquo.python.Python
import com.chaquo.python.android.AndroidPlatform
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors

internal class VideoWebStreams(private val activity: Activity) {
    private val workers = Executors.newFixedThreadPool(2)
    private var closed = false

    fun resolve(url: String?, format: String?, result: MethodChannel.Result) {
        if (url.isNullOrBlank() || url.length > 8192 || format.isNullOrBlank() || format.length > 2048) {
            result.error("video_url", "Enter a valid web video URL.", null)
            return
        }
        workers.execute {
            val resolved = runCatching {
                synchronized(Python::class.java) {
                    if (!Python.isStarted()) {
                        Python.start(AndroidPlatform(activity.applicationContext))
                    }
                }
                val executable = File(activity.applicationInfo.nativeLibraryDir, "libqjs.so").path
                Python.getInstance().getModule("auralis_streams")
                    .callAttr("resolve", url, format, executable).toString()
            }
            activity.runOnUiThread {
                if (!closed) {
                    resolved.fold(result::success) {
                        result.error("video_extract", "This site did not return a playable stream.", null)
                    }
                }
            }
        }
    }

    fun close() {
        closed = true
        workers.shutdownNow()
    }
}
