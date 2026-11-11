package com.auralis.siam

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.DocumentsContract
import android.provider.DocumentsContract.Document
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
    private var folderPicker: MethodChannel.Result? = null
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

    fun openFolder(result: MethodChannel.Result) {
        if (folderPicker != null) {
            result.error("busy", "A folder picker is already open.", null)
            return
        }
        folderPicker = result
        try {
            @Suppress("DEPRECATION")
            activity.startActivityForResult(
                Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).addFlags(
                    Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION,
                ),
                PICK_FOLDER,
            )
        } catch (failure: Exception) {
            folderPicker = null
            throw failure
        }
    }

    fun onActivityResult(code: Int, status: Int, intent: Intent?): Boolean {
        if (code != PICK_FOLDER) return false
        val result = folderPicker ?: return true
        folderPicker = null
        val tree = intent?.data
        if (status != Activity.RESULT_OK || tree == null) {
            result.success(null)
            return true
        }
        work(result) {
            require(DocumentsContract.isTreeUri(tree))
            val resolver = activity.contentResolver
            resolver.takePersistableUriPermission(tree, Intent.FLAG_GRANT_READ_URI_PERMISSION)
            val root = DocumentsContract.buildDocumentUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))
            mapOf("uri" to tree.toString(), "name" to displayName(root, "Video folder"))
        }
        return true
    }

    fun listFolder(treeValue: String?, folderValue: String?, result: MethodChannel.Result) = work(result) {
        val tree = grantedTree(treeValue)
        val root = DocumentsContract.getTreeDocumentId(tree)
        val folder = if (folderValue.isNullOrEmpty()) root else {
            val uri = Uri.parse(folderValue)
            require(uri.authority == tree.authority && DocumentsContract.getTreeDocumentId(uri) == root)
            DocumentsContract.getDocumentId(uri)
        }
        val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, folder)
        val resolver = activity.contentResolver
        val resultRows = mutableListOf<Map<String, Any>>()
        resolver.query(children, arrayOf(
            Document.COLUMN_DOCUMENT_ID, Document.COLUMN_DISPLAY_NAME,
            Document.COLUMN_MIME_TYPE, Document.COLUMN_LAST_MODIFIED, Document.COLUMN_SIZE,
        ), null, null, null)?.use { cursor ->
            var scanned = 0
            while (scanned < 10000 && cursor.moveToNext()) {
                scanned++
                val id = cursor.getString(0) ?: continue
                val name = cursor.getString(1) ?: continue
                val mime = cursor.getString(2).orEmpty()
                val directory = mime == Document.MIME_TYPE_DIR
                if (!directory && !mime.startsWith("video/") && !isVideoName(name)) continue
                val uri = DocumentsContract.buildDocumentUriUsingTree(tree, id)
                resultRows.add(mapOf(
                    "uri" to uri.toString(), "name" to name, "folder" to directory,
                    "modified" to cursor.getLong(3), "size" to cursor.getLong(4),
                ))
            }
        } ?: throw IllegalStateException("Folder unavailable")
        resultRows
    }

    fun forgetFolder(value: String?, result: MethodChannel.Result) = work(result) {
        val uri = Uri.parse(value ?: error("Folder required"))
        if (activity.contentResolver.persistedUriPermissions.any { it.uri == uri && it.isReadPermission }) {
            activity.contentResolver.releasePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        null
    }

    fun describe(uris: Iterable<Uri>): List<Map<String, String>> = uris.filter { it.scheme == "content" }.map {
        mapOf("uri" to it.toString(), "name" to displayName(it, "Video"))
    }

    private fun grantedTree(value: String?): Uri {
        val uri = Uri.parse(value ?: error("Folder required"))
        require(DocumentsContract.isTreeUri(uri))
        require(activity.contentResolver.persistedUriPermissions.any { it.uri == uri && it.isReadPermission })
        return uri
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
        folderPicker?.success(null)
        folderPicker = null
        incoming.setMethodCallHandler(null)
    }

    companion object {
        private const val PICK_FOLDER = 4105
        private val extensions = setOf("mp4", "mkv", "webm", "mov", "avi", "m4v", "mpg", "mpeg", "ts", "m2ts", "wmv", "flv", "ogv", "3gp")
        private fun isVideoName(name: String) = name.substringAfterLast('.', "").lowercase() in extensions

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
