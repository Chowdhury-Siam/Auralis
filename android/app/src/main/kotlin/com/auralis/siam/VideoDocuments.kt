package com.auralis.siam

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.OpenableColumns
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executor

internal class VideoDocuments(
    private val activity: Activity,
    messenger: BinaryMessenger,
    private val io: Executor,
) {
    private val incoming = MethodChannel(messenger, "app.auralis/video_intents")
    private var pendingIntent: List<Uri> = emptyList()
    private var closed = false

    init {
        incoming.setMethodCallHandler { call, result ->
            if (call.method == "takeIncomingVideos") {
                val files = pendingIntent
                pendingIntent = emptyList()
                work(result) { describe(files) }
            } else {
                result.notImplemented()
            }
        }
    }

    fun accept(intent: Intent) {
        if (intent.action !in setOf(Intent.ACTION_VIEW, Intent.ACTION_SEND, Intent.ACTION_SEND_MULTIPLE)
            || intent.type?.startsWith("video/") != true
        ) return
        val files = intentFiles(intent).filter { it.scheme == "content" }.take(200)
        if (files.isEmpty()) return
        pendingIntent = files
        incoming.invokeMethod("incomingVideos", null)
    }

    fun describe(uris: Iterable<Uri>): List<Map<String, String>> = uris.filter { it.scheme == "content" }.map {
        mapOf("uri" to it.toString(), "name" to displayName(it, "Video"))
    }

    private fun displayName(uri: Uri, fallback: String): String = runCatching {
        activity.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use {
            if (it.moveToFirst()) it.getString(0) else null
        }
    }.getOrNull() ?: fallback

    private fun work(result: MethodChannel.Result, read: () -> Any?) {
        io.execute {
            try {
                val value = read()
                activity.runOnUiThread { if (!closed) result.success(value) }
            } catch (_: Exception) {
                activity.runOnUiThread {
                    if (!closed) result.error("video_document", "Android could not access the selected videos.", null)
                }
            }
        }
    }

    fun close() {
        closed = true
        incoming.setMethodCallHandler(null)
    }

    companion object {
        @Suppress("DEPRECATION")
        fun intentFiles(intent: Intent): Set<Uri> = linkedSetOf<Uri>().apply {
            intent.data?.let(::add)
            intent.clipData?.let { clip ->
                for (i in 0 until minOf(clip.itemCount, 200)) clip.getItemAt(i).uri?.let(::add)
            }
            if (intent.action == Intent.ACTION_SEND) {
                val file = if (Build.VERSION.SDK_INT >= 33) {
                    intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
                } else intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)
                file?.let(::add)
            } else if (intent.action == Intent.ACTION_SEND_MULTIPLE) {
                val files = if (Build.VERSION.SDK_INT >= 33) {
                    intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
                } else intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)
                files?.take(200)?.let(::addAll)
            }
        }
    }
}
