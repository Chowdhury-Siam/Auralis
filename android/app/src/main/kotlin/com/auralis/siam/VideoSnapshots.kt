package com.auralis.siam

import android.Manifest
import android.annotation.TargetApi
import android.app.Activity
import android.content.ContentValues
import android.content.pm.PackageManager
import android.media.MediaScannerConnection
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.IOException
import java.util.concurrent.Executor

internal class VideoSnapshots(private val activity: Activity, private val io: Executor) {
    companion object {
        private const val STORAGE_REQUEST = 4105
    }

    private class Capture(val name: String, val bytes: ByteArray, val result: MethodChannel.Result)

    private var pending: Capture? = null
    private var closed = false

    @Suppress("DEPRECATION")
    fun save(name: String, bytes: ByteArray, result: MethodChannel.Result) {
        require(name.endsWith(".png") && '/' !in name && '\\' !in name && bytes.isNotEmpty())
        val capture = Capture(name, bytes, result)
        if (Build.VERSION.SDK_INT >= 29 || canWriteDownloads()) {
            write(capture)
            return
        }
        if (pending != null) {
            result.error("snapshot_busy", "A snapshot is waiting for storage access.", null)
            return
        }
        pending = capture
        try {
            activity.requestPermissions(arrayOf(Manifest.permission.WRITE_EXTERNAL_STORAGE), STORAGE_REQUEST)
        } catch (error: Exception) {
            pending = null
            throw error
        }
    }

    fun onPermissionsResult(requestCode: Int): Boolean {
        if (requestCode != STORAGE_REQUEST) return false
        val capture = pending ?: return true
        pending = null
        if (canWriteDownloads()) {
            write(capture)
        } else {
            capture.result.error("snapshot_permission", "Allow storage access to save snapshots.", null)
        }
        return true
    }

    @Suppress("DEPRECATION")
    private fun canWriteDownloads() =
        activity.checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) == PackageManager.PERMISSION_GRANTED

    private fun write(capture: Capture) {
        io.execute {
            val saved = runCatching {
                if (Build.VERSION.SDK_INT >= 29) writeUsingMediaStore(capture)
                else writeLegacyFile(capture)
            }.isSuccess
            activity.runOnUiThread {
                if (!closed) {
                    if (saved) capture.result.success(null)
                    else capture.result.error("snapshot_write", "Could not save the snapshot to Download/Snapshots.", null)
                }
            }
        }
    }

    @TargetApi(29)
    private fun writeUsingMediaStore(capture: Capture) {
        val resolver = activity.contentResolver
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, capture.name)
            put(MediaStore.MediaColumns.MIME_TYPE, "image/png")
            put(MediaStore.MediaColumns.RELATIVE_PATH, "${Environment.DIRECTORY_DOWNLOADS}/Snapshots")
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }
        val collection = MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        val uri = resolver.insert(collection, values)
            ?: throw IOException("Could not create a download")
        try {
            val stream = resolver.openOutputStream(uri) ?: throw IOException("Could not open the download")
            stream.use { it.write(capture.bytes) }
            val ready = ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) }
            check(resolver.update(uri, ready, null, null) == 1) { "Could not publish the snapshot" }
        } catch (error: Exception) {
            runCatching { resolver.delete(uri, null, null) }
            throw error
        }
    }

    @Suppress("DEPRECATION")
    private fun writeLegacyFile(capture: Capture) {
        val downloads = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
        val directory = File(downloads, "Snapshots")
        if (!directory.mkdirs() && !directory.isDirectory) throw IOException("Could not create Snapshots")
        val temporary = File.createTempFile("snapshot-", ".partial", directory)
        val destination = File(directory, capture.name)
        try {
            temporary.writeBytes(capture.bytes)
            if (destination.exists() || !temporary.renameTo(destination)) {
                throw IOException("Could not publish the snapshot")
            }
        } finally {
            temporary.delete()
        }
        MediaScannerConnection.scanFile(activity, arrayOf(destination.path), arrayOf("image/png"), null)
    }

    fun close() {
        closed = true
        pending?.result?.error("snapshot_closed", "The video screen closed before saving the snapshot.", null)
        pending = null
    }
}
