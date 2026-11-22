package com.auralis.siam

import android.Manifest
import android.app.Activity
import android.content.ContentUris
import android.content.Intent
import android.content.pm.PackageManager
import android.database.ContentObserver
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.provider.Settings
import android.util.Size
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
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
    private var accessRequest: Pair<Boolean, MethodChannel.Result>? = null
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
            val video = call.arguments == true
            try {
                when (call.method) {
                    "access" -> result.success(access(video))
                    "requestAccess" -> requestAccess(video, result)
                    "settings" -> {
                        val intent = Intent(
                            Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                            Uri.fromParts("package", activity.packageName, null),
                        )
                        activity.startActivity(intent)
                        result.success(null)
                    }
                    "scan" -> scanner.execute {
                        work(result) {
                            val rows = scan(video)
                            val token = ++sequence
                            snapshots[token] = rows
                            mapOf("token" to token, "count" to rows.size)
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
                            if (uri.scheme != "content" || uri.authority != MediaStore.AUTHORITY) null
                            else artwork(uri, call.argument<Boolean>("video") == true)
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

    private fun granted(permission: String) =
        activity.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED

    @Suppress("DEPRECATION")
    private fun permission(video: Boolean) = when {
        Build.VERSION.SDK_INT < 33 -> Manifest.permission.READ_EXTERNAL_STORAGE
        video -> Manifest.permission.READ_MEDIA_VIDEO
        else -> Manifest.permission.READ_MEDIA_AUDIO
    }

    private fun access(video: Boolean): String = when {
        granted(permission(video)) -> "full"
        video && Build.VERSION.SDK_INT >= 34 &&
            granted(Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED) -> "limited"
        else -> "denied"
    }

    private fun requestAccess(video: Boolean, result: MethodChannel.Result) {
        if (access(video) == "full") {
            result.success("full")
            return
        }
        if (accessRequest != null) {
            result.error("busy", "A media permission request is already open.", null)
            return
        }
        val permissions = if (video && Build.VERSION.SDK_INT >= 34) {
            arrayOf(permission(true), Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED)
        } else {
            arrayOf(permission(video))
        }
        accessRequest = video to result
        try {
            activity.requestPermissions(permissions, ACCESS_REQUEST)
        } catch (error: Exception) {
            accessRequest = null
            throw error
        }
    }

    fun onPermissionsResult(requestCode: Int): Boolean {
        if (requestCode != ACCESS_REQUEST) return false
        val pending = accessRequest
        accessRequest = null
        if (pending != null) pending.second.success(access(pending.first))
        return true
    }

    private fun collection(video: Boolean, volume: String = "external"): Uri =
        if (video) MediaStore.Video.Media.getContentUri(volume)
        else MediaStore.Audio.Media.getContentUri(volume)

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

    @Suppress("DEPRECATION")
    private fun scan(video: Boolean): List<Map<String, Any>> {
        if (access(video) == "denied") return emptyList()
        val rows = mutableListOf<Map<String, Any>>()
        val store = collection(video)
        val columns = mutableListOf("_id", "_display_name", "_size", "date_modified", "title", "duration")
        if (Build.VERSION.SDK_INT >= 29) columns.addAll(listOf("relative_path", "volume_name"))
        else columns.add("_data")
        if (!video) {
            columns.addAll(listOf("artist", "album", "album_id"))
            if (Build.VERSION.SDK_INT >= 30) columns.addAll(listOf("album_artist", "genre"))
        }
        val legacyGenres = if (!video && Build.VERSION.SDK_INT < 30) genres() else emptyMap()
        resolver.query(store, columns.toTypedArray(), null, null, null)?.use { cursor ->
            val indices = cursor.columnNames.withIndex().associate { it.value to it.index }
            fun text(name: String): String? = indices[name]?.let { cursor.getString(it) }
            fun number(name: String): Long = indices[name]?.let { cursor.getLong(it) } ?: 0
            while (cursor.moveToNext()) {
                val id = number("_id")
                val volume = text("volume_name")
                val relative = text("relative_path")?.trimEnd('/') ?: ""
                val folder = when {
                    Build.VERSION.SDK_INT < 29 -> text("_data")?.substringBeforeLast('/') ?: ""
                    volume == null || volume == "external_primary" -> relative
                    relative.isEmpty() -> volume
                    else -> "$volume/$relative"
                }
                val row = mutableMapOf<String, Any>(
                    "uri" to ContentUris.withAppendedId(
                        if (volume == null) store else collection(video, volume),
                        id,
                    ).toString(),
                    "folder" to folder,
                    "date" to (number("date_modified") * 1000),
                    "size" to number("_size"),
                    "duration" to number("duration"),
                )
                text("_display_name")?.let { row["name"] = it }
                // Video filenames often contain the episode number missing from tags.
                if (!video) {
                    for ((column, field) in listOf(
                        "title" to "title", "artist" to "artist", "album" to "album",
                        "album_artist" to "albumArtist", "genre" to "genre",
                    )) text(column)?.let { row[field] = it }
                    val albumId = number("album_id")
                    if (albumId > 0 && text("album") !in setOf(null, "", "<unknown>")) {
                        row["albumKey"] = "${volume ?: "external"}/$albumId"
                    }
                    legacyGenres[id]?.let { row["genre"] = it }
                }
                rows.add(row)
            }
        }
        return rows
    }

    @Suppress("DEPRECATION")
    private fun genres(): Map<Long, String> = runCatching {
        val genres = mutableMapOf<Long, String>()
        resolver.query(
            MediaStore.Audio.Genres.EXTERNAL_CONTENT_URI,
            arrayOf("_id", "name"), null, null, "name",
        )?.use { names ->
            while (names.moveToNext()) {
                val genre = names.getString(1) ?: continue
                val members = MediaStore.Audio.Genres.Members.getContentUri("external", names.getLong(0))
                resolver.query(members, arrayOf("audio_id"), null, null, null)?.use {
                    while (it.moveToNext()) genres.putIfAbsent(it.getLong(0), genre)
                }
            }
        }
        genres
    }.getOrDefault(emptyMap())

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

    private fun openSongs(result: MethodChannel.Result) {
        if (songPicker != null) {
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
        accessRequest?.second?.success("denied")
        accessRequest = null
        songPicker?.success(emptyList<Map<String, String>>())
        songPicker = null
        scanner.shutdown()
        images.shutdown()
    }

    private companion object {
        const val ACCESS_REQUEST = 4112
        const val SONG_PICKER = 4113
    }
}
