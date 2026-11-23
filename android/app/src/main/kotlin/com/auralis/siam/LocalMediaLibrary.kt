package com.auralis.siam

import android.app.Activity
import android.content.Intent
import android.database.ContentObserver
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import android.provider.DocumentsContract.Document
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.system.Os
import android.util.Size
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.util.Locale
import java.util.concurrent.Executors

internal class LocalMediaLibrary(
    private val activity: Activity,
    messenger: BinaryMessenger,
) : EventChannel.StreamHandler {
    private val resolver = activity.contentResolver
    private val channel = MethodChannel(messenger, "app.auralis/local_media")
    private val events = EventChannel(messenger, "app.auralis/local_media_changes")
    private val scanner = Executors.newSingleThreadExecutor()
    private val images = Executors.newFixedThreadPool(2)
    // The scanner owns these snapshots. Bounded pages keep channel decoding
    // work small on Flutter's UI isolate.
    private val snapshots = mutableMapOf<Int, List<Map<String, Any>>>()
    private var sequence = 0
    private var folderPicker: MethodChannel.Result? = null
    private var songPicker: MethodChannel.Result? = null
    private var sink: EventChannel.EventSink? = null
    private val observer = object : ContentObserver(Handler(Looper.getMainLooper())) {
        override fun onChange(selfChange: Boolean) {
            sink?.success(null)
        }
    }

    init {
        events.setStreamHandler(this)
        channel.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "chooseFolder" -> chooseFolder(result)
                    "scanFolders" -> scanner.execute {
                        work(result) {
                            val (rows, unavailable) = scanFolders(
                                call.argument<Boolean>("video") == true,
                                call.argument<List<String>>("folders").orEmpty(),
                                call.argument<List<String>>("extensions").orEmpty().toSet(),
                            )
                            val token = ++sequence
                            snapshots[token] = rows
                            mapOf("token" to token, "count" to rows.size, "unavailable" to unavailable)
                        }
                    }
                    "scanPage" -> scanner.execute {
                        work(result) {
                            val token = call.argument<Int>("token")
                            val start = call.argument<Int>("start") ?: 0
                            val rows = snapshots[token] ?: emptyList()
                            if (start in rows.indices) rows.subList(start, minOf(start + 512, rows.size))
                            else emptyList()
                        }
                    }
                    "finishScan" -> scanner.execute {
                        work(result) {
                            snapshots.remove(call.arguments)
                            null
                        }
                    }
                    "artwork" -> images.execute {
                        work(result) {
                            val uri = Uri.parse(call.argument<String>("uri") ?: "")
                            if (uri.scheme != "content") null
                            else artwork(uri, call.argument<Boolean>("video") == true)
                        }
                    }
                    "metadata" -> images.execute {
                        work(result) {
                            val uri = Uri.parse(call.arguments as? String ?: "")
                            if (uri.scheme == "content") songMetadata(uri) else emptyMap<String, Any>()
                        }
                    }
                    "audioSize" -> images.execute {
                        work(result) {
                            val uri = Uri.parse(call.arguments as? String ?: "")
                            require(uri.scheme == "content")
                            resolver.openAssetFileDescriptor(uri, "r")?.use { it.length }
                        }
                    }
                    "audioRange" -> images.execute {
                        work(result) {
                            val uri = Uri.parse(call.argument<String>("uri").orEmpty())
                            val offset = call.argument<Number>("offset")?.toLong() ?: -1L
                            val count = call.argument<Int>("count") ?: 0
                            readAudioRange(uri, offset, count)
                        }
                    }
                    "openSongs" -> openSongs(result)
                    else -> result.notImplemented()
                }
            } catch (_: Exception) {
                result.error("local_media", "Could not access local media.", null)
            }
        }
    }

    private fun readAudioRange(uri: Uri, offset: Long, count: Int): ByteArray? {
        require(uri.scheme == "content" && offset >= 0 && count in 1..(4 * 1024 * 1024))
        return resolver.openAssetFileDescriptor(uri, "r")?.use { asset ->
            val size = asset.length
            if (size < count || offset > size - count) return@use null
            val bytes = ByteArray(count)
            var read = 0
            while (read < count) {
                val position = asset.startOffset + offset + read
                val length = Os.pread(asset.fileDescriptor, bytes, read, count - read, position)
                if (length <= 0) return@use null
                read += length
            }
            bytes
        }
    }

    private fun work(result: MethodChannel.Result, action: () -> Any?) {
        try {
            // MethodChannel results can be submitted from a worker thread.
            result.success(action())
        } catch (_: SecurityException) {
            result.error("media_access", "Android media access has changed.", null)
        } catch (_: Exception) {
            result.error("local_media", "Could not read local media.", null)
        }
    }

    override fun onListen(arguments: Any?, eventSink: EventChannel.EventSink) {
        sink = eventSink
        try {
            // Observe all external volumes, including notifications for a
            // specific volume rather than the merged external collection.
            resolver.registerContentObserver(
                Uri.parse("content://${MediaStore.AUTHORITY}"), true, observer,
            )
        } catch (_: Exception) {
            onCancel(null)
            eventSink.error("media_observer", "Could not watch for media changes.", null)
        }
    }

    override fun onCancel(arguments: Any?) {
        if (sink != null) resolver.unregisterContentObserver(observer)
        sink = null
    }

    private fun scanFolders(
        video: Boolean,
        folders: List<String>,
        extensions: Set<String>,
    ): Pair<List<Map<String, Any>>, Int> {
        val rows = mutableListOf<Map<String, Any>>()
        val visited = mutableSetOf<Pair<String, String>>()
        val files = mutableSetOf<Pair<String, String>>()
        val grants = resolver.persistedUriPermissions
            .filter { it.isReadPermission }.map { it.uri }.toSet()
        val columns = arrayOf(
            Document.COLUMN_DOCUMENT_ID, Document.COLUMN_DISPLAY_NAME, Document.COLUMN_MIME_TYPE,
            Document.COLUMN_LAST_MODIFIED, Document.COLUMN_SIZE, Document.COLUMN_FLAGS,
        )
        val prefix = if (video) "video/" else "audio/"
        var unavailable = 0
        for (folder in folders) {
            val tree = Uri.parse(folder)
            val authority = tree.authority
            if (tree.scheme != "content" || authority == null || tree !in grants ||
                !DocumentsContract.isTreeUri(tree)) {
                unavailable++
                continue
            }
            val rootId = DocumentsContract.getTreeDocumentId(tree)
            val rootName = folderName(tree) ?: rootId.substringAfterLast('/').substringAfter(':')
            val pending = ArrayDeque<Pair<String, String>>()
            pending.add(rootId to rootName)
            while (pending.isNotEmpty()) {
                val (id, path) = pending.removeLast()
                val key = authority to id
                if (key in visited) continue
                val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, id)
                val folderKey = DocumentsContract.buildDocumentUri(authority, id).toString()
                try {
                    val cursor = resolver.query(children, columns, null, null, null)
                    if (cursor == null) {
                        unavailable++
                        continue
                    }
                    visited.add(key)
                    cursor.use {
                        while (it.moveToNext()) {
                            val childId = it.getString(0) ?: continue
                            val name = it.getString(1) ?: continue
                            val mime = it.getString(2).orEmpty()
                            if (mime == Document.MIME_TYPE_DIR) {
                                pending.add(childId to "$path/$name")
                            } else if ((it.getInt(5) and Document.FLAG_VIRTUAL_DOCUMENT) == 0 &&
                                (mime.startsWith(prefix) || name.substringAfterLast('.', "")
                                    .lowercase(Locale.ROOT) in extensions) &&
                                files.add(authority to childId)) {
                                rows.add(mapOf(
                                    "uri" to DocumentsContract.buildDocumentUriUsingTree(tree, childId).toString(),
                                    "name" to name,
                                    "folder" to path,
                                    "folderKey" to folderKey,
                                    "date" to it.getLong(3),
                                    "size" to it.getLong(4),
                                ))
                            }
                        }
                    }
                } catch (_: Exception) {
                    unavailable++
                }
            }
        }
        return rows to unavailable
    }

    private fun folderName(tree: Uri): String? = runCatching {
        val root = DocumentsContract.buildDocumentUriUsingTree(
            tree, DocumentsContract.getTreeDocumentId(tree),
        )
        resolver.query(root, arrayOf(Document.COLUMN_DISPLAY_NAME), null, null, null)
            ?.use { if (it.moveToFirst()) it.getString(0) else null }
    }.getOrNull()

    private fun songMetadata(uri: Uri): Map<String, Any> {
        val reader = MediaMetadataRetriever()
        try {
            reader.setDataSource(activity, uri)
            val tags = mutableMapOf<String, Any>()
            for ((field, tag) in listOf(
                "title" to MediaMetadataRetriever.METADATA_KEY_TITLE,
                "artist" to MediaMetadataRetriever.METADATA_KEY_ARTIST,
                "album" to MediaMetadataRetriever.METADATA_KEY_ALBUM,
                "albumArtist" to MediaMetadataRetriever.METADATA_KEY_ALBUMARTIST,
                "genre" to MediaMetadataRetriever.METADATA_KEY_GENRE,
            )) reader.extractMetadata(tag)?.let { tags[field] = it }
            reader.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
                ?.toLongOrNull()?.let { tags["duration"] = it }
            return tags
        } finally {
            reader.release()
        }
    }

    private fun artwork(uri: Uri, video: Boolean): ByteArray? {
        val bitmap = if (Build.VERSION.SDK_INT >= 29) {
            runCatching { resolver.loadThumbnail(uri, Size(144, 144), null) }.getOrNull()
        } else null
        val image = bitmap ?: run {
            val reader = MediaMetadataRetriever()
            try {
                reader.setDataSource(activity, uri)
                if (video) {
                    if (Build.VERSION.SDK_INT >= 27)
                        reader.getScaledFrameAtTime(-1, MediaMetadataRetriever.OPTION_CLOSEST_SYNC, 144, 144)
                    else reader.getFrameAtTime(-1, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
                } else {
                    reader.embeddedPicture?.let(::decodeCover)
                }
            } finally {
                reader.release()
            }
        } ?: return null
        val scale = maxOf(image.width, image.height) / 144.0
        val thumbnail = if (scale > 1) Bitmap.createScaledBitmap(
            image, maxOf(1, (image.width / scale).toInt()), maxOf(1, (image.height / scale).toInt()), true,
        ) else image
        try {
            return ByteArrayOutputStream().use {
                thumbnail.compress(Bitmap.CompressFormat.JPEG, 83, it)
                it.toByteArray()
            }
        } finally {
            if (thumbnail !== image) thumbnail.recycle()
            image.recycle()
        }
    }

    private fun decodeCover(bytes: ByteArray): Bitmap? {
        val options = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options)
        if (options.outWidth <= 0 || options.outHeight <= 0) return null
        options.inSampleSize = 1
        while (maxOf(options.outWidth, options.outHeight) / options.inSampleSize > 288) {
            options.inSampleSize *= 2
        }
        options.inJustDecodeBounds = false
        return BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options)
    }

    private fun chooseFolder(result: MethodChannel.Result) {
        if (folderPicker != null || songPicker != null) {
            result.error("busy", "A picker is already open.", null)
            return
        }
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).addFlags(
            Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION,
        )
        folderPicker = result
        try {
            @Suppress("DEPRECATION")
            activity.startActivityForResult(intent, FOLDER_PICKER)
        } catch (error: Exception) {
            folderPicker = null
            throw error
        }
    }

    private fun openSongs(result: MethodChannel.Result) {
        if (songPicker != null || folderPicker != null) {
            result.error("busy", "A file picker is already open.", null)
            return
        }
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT)
            .addCategory(Intent.CATEGORY_OPENABLE)
            .setType("audio/*")
            .putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        songPicker = result
        try {
            @Suppress("DEPRECATION")
            activity.startActivityForResult(intent, SONG_PICKER)
        } catch (error: Exception) {
            songPicker = null
            throw error
        }
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode == FOLDER_PICKER) {
            val result = folderPicker ?: return true
            folderPicker = null
            val tree = data?.data
            if (resultCode != Activity.RESULT_OK || tree == null) {
                result.success(null)
                return true
            }
            scanner.execute {
                work(result) {
                    require(tree.scheme == "content" && DocumentsContract.isTreeUri(tree))
                    resolver.takePersistableUriPermission(tree, Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    val name = folderName(tree) ?: "Folder"
                    mapOf("uri" to tree.toString(), "name" to name)
                }
            }
            return true
        }
        if (requestCode != SONG_PICKER) return false
        val result = songPicker ?: return true
        songPicker = null
        if (resultCode != Activity.RESULT_OK || data == null) {
            result.success(emptyList<Map<String, String>>())
            return true
        }
        val files = VideoDocuments.intentFiles(data).filter { it.scheme == "content" }
        scanner.execute {
            work(result) {
                files.map { uri ->
                    val name = runCatching {
                        resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
                            ?.use { if (it.moveToFirst()) it.getString(0) else null }
                    }.getOrNull()
                    mapOf("uri" to uri.toString(), "name" to (name ?: "Song"))
                }
            }
        }
        return true
    }

    fun close() {
        onCancel(null)
        events.setStreamHandler(null)
        channel.setMethodCallHandler(null)
        folderPicker?.success(null)
        folderPicker = null
        songPicker?.success(emptyList<Map<String, String>>())
        songPicker = null
        scanner.shutdown()
        images.shutdown()
    }

    private companion object {
        const val FOLDER_PICKER = 4112
        const val SONG_PICKER = 4113
    }
}
