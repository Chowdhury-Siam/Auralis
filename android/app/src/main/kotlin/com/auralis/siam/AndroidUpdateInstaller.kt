package com.auralis.siam

import android.app.Activity
import android.app.PendingIntent
import android.content.ClipData
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageInstaller
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.lang.ref.WeakReference
import java.security.MessageDigest
import java.util.concurrent.ExecutorService
import java.util.zip.ZipFile

/** Only verified, newer, same-package and same-signature APKs reach Android's installer. */
class AndroidUpdateInstaller(private val activity: Activity, private val io: ExecutorService) {
    companion object {
        const val PERMISSION_REQUEST = 4201
    }
    private data class Request(val file: File, val version: String, val digest: String)
    @Volatile private var pending: Pair<Request, MethodChannel.Result>? = null
    @Volatile private var sessionId = -1
    private val directory: File
        get() = File(activity.cacheDir, "auralis-updates").canonicalFile
    private val abi: String?
        get() = Build.SUPPORTED_64_BIT_ABIS.firstOrNull { it == "arm64-v8a" || it == "x86_64" }

    fun info(): Map<String, String?> {
        check(directory.isDirectory || directory.mkdirs()) { "Update cache is unavailable." }
        return mapOf("abi" to abi, "directory" to directory.path)
    }

    fun install(call: MethodCall, result: MethodChannel.Result) {
        if (pending != null) {
            result.error("update_busy", "An update installation is already open.", null)
            return
        }
        val path = call.argument<String>("path")
        val version = call.argument<String>("version")
        val digest = call.argument<String>("sha256")
        if (path == null || version == null || digest == null ||
            !Regex("[0-9a-f]{64}").matches(digest)) {
            result.error("update_invalid", "Invalid update request. Download the update again.", null)
            return
        }
        val request = Request(File(path), version, digest)
        pending = request to result
        prepare(request, result)
    }

    private fun prepare(request: Request, result: MethodChannel.Result) {
        io.execute {
            try {
                verify(request)
                activity.runOnUiThread {
                    if (pending?.second !== result) return@runOnUiThread
                    try {
                        if (Build.VERSION.SDK_INT >= 26 && !activity.packageManager.canRequestPackageInstalls()) {
                            activity.startActivityForResult(
                                Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                                    Uri.parse("package:${activity.packageName}")), PERMISSION_REQUEST)
                        } else if (Build.VERSION.SDK_INT >= 31) {
                            installSession(request, result)
                        } else {
                            val uri = FileProvider.getUriForFile(activity, "${activity.packageName}.updates", request.file.canonicalFile)
                            val intent = Intent(Intent.ACTION_VIEW)
                                .setDataAndType(uri, "application/vnd.android.package-archive")
                                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                            intent.clipData = ClipData.newRawUri("Auralis update", uri)
                            activity.startActivity(intent)
                            pending = null
                            result.success(true)
                        }
                    } catch (_: Exception) {
                        pending = null
                        result.error("update_installer", "Android could not open the install permission page or APK installer. Try again.", null)
                    }
                }
            } catch (error: Exception) {
                activity.runOnUiThread {
                    if (pending?.second !== result) return@runOnUiThread
                    pending = null
                    result.error("update_verification", error.message ?: "The update APK could not be verified.", null)
                }
            }
        }
    }

    @android.annotation.TargetApi(31)
    private fun installSession(request: Request, result: MethodChannel.Result) {
        io.execute {
            val installer = activity.packageManager.packageInstaller
            var id = -1
            try {
                val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL)
                params.setAppPackageName(activity.packageName)
                params.setSize(request.file.length())
                params.setRequireUserAction(PackageInstaller.SessionParams.USER_ACTION_NOT_REQUIRED)
                id = installer.createSession(params)
                sessionId = id
                UpdateInstallReceiver.owner = WeakReference(this)
                installer.openSession(id).use { session ->
                    session.openWrite("base.apk", 0, request.file.length()).use { output ->
                        request.file.inputStream().use { it.copyTo(output) }
                        session.fsync(output)
                    }
                    val callback = Intent(activity, UpdateInstallReceiver::class.java)
                        .setAction(UpdateInstallReceiver.ACTION)
                    val sender = PendingIntent.getBroadcast(activity, id, callback,
                        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE)
                    check(pending?.second === result) { "Installation was closed before submission" }
                    session.commit(sender.intentSender)
                }
            } catch (_: Exception) {
                if (id >= 0) runCatching { installer.abandonSession(id) }
                activity.runOnUiThread {
                    if (pending?.second !== result) return@runOnUiThread
                    sessionId = -1
                    pending = null
                    result.error("update_installer", "Android could not start the update. Your download is kept; try again.", null)
                }
            }
        }
    }

    internal fun installResult(id: Int, status: Int, message: String?): Boolean {
        if (id != sessionId) return false
        val current = pending ?: return false
        sessionId = -1
        pending = null
        if (status == PackageInstaller.STATUS_SUCCESS) {
            current.second.success(true)
        } else {
            current.second.error("update_installer", message ?: "Android did not install the update. Try again.", null)
        }
        return true
    }

    fun onActivityResult(requestCode: Int): Boolean {
        if (requestCode != PERMISSION_REQUEST) return false
        val current = pending ?: return true
        if (Build.VERSION.SDK_INT >= 26 && !activity.packageManager.canRequestPackageInstalls()) {
            pending = null
            current.second.error("update_permission", "Allow Auralis to install updates from this source, then tap Install update again.", null)
        } else {
            // Recheck the file after returning from the system permission screen.
            prepare(current.first, current.second)
        }
        return true
    }

    @Suppress("DEPRECATION")
    private fun verify(request: Request) {
        val file = request.file.canonicalFile
        require(file.path.startsWith(directory.path + File.separator) && file.extension == "apk" &&
            file.isFile && file.length() in 1L..(512L * 1024 * 1024)) { "Choose an APK downloaded by Auralis." }
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(64 * 1024)
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                digest.update(buffer, 0, count)
            }
        }
        val actual = digest.digest().joinToString("") { "%02x".format(it.toInt() and 0xff) }
        require(actual == request.digest) { "The update changed after download. Download it again." }
        val flags = if (Build.VERSION.SDK_INT >= 28) PackageManager.GET_SIGNING_CERTIFICATES else PackageManager.GET_SIGNATURES
        val archive = activity.packageManager.getPackageArchiveInfo(file.path, flags)
            ?: throw IllegalArgumentException("The update is not a valid Android APK.")
        val installed = activity.packageManager.getPackageInfo(activity.packageName, flags)
        require(archive.packageName == activity.packageName) { "This APK belongs to a different app package." }
        require(archive.versionName == request.version) { "The APK version does not match its release." }
        require(versionCode(archive) > versionCode(installed)) { "This update is already installed or is older than your app." }
        val signatures = certificates(installed)
        require(signatures.isNotEmpty() && signatures == certificates(archive)) {
            "The APK signing key does not match this installation. Use APKs built with the same retained Android signing identity."
        }
        ZipFile(file).use { zip ->
            require(abi != null && zip.getEntry("lib/$abi/libflutter.so") != null) {
                "This APK does not support this device's architecture."
            }
        }
    }

    @Suppress("DEPRECATION")
    private fun versionCode(info: PackageInfo): Long =
        if (Build.VERSION.SDK_INT >= 28) info.longVersionCode else info.versionCode.toLong()

    @Suppress("DEPRECATION")
    private fun certificates(info: PackageInfo): Set<String> {
        val values = if (Build.VERSION.SDK_INT >= 28) info.signingInfo?.apkContentsSigners else info.signatures
        return values?.map { signature ->
            MessageDigest.getInstance("SHA-256").digest(signature.toByteArray())
                .joinToString("") { "%02x".format(it.toInt() and 0xff) }
        }?.toSet() ?: emptySet()
    }

    fun close() {
        if (UpdateInstallReceiver.owner?.get() === this) UpdateInstallReceiver.owner = null
        pending?.second?.error("update_cancelled", "Installation was interrupted. Reopen Auralis and try again.", null)
        pending = null
        sessionId = -1
    }
}
