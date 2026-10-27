package com.auralis.siam

import android.app.Activity
import android.content.Intent
import android.net.Uri
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

class MainActivity : AudioServiceActivity() {
    private val io = Executors.newSingleThreadExecutor()
    private val vault = VaultCipher()
    private val updates by lazy { AndroidUpdateInstaller(this, io) }
    private val setup by lazy { DeviceSetup(this) }
    private var pending: MethodChannel.Result? = null
    private var selectedRead: Uri? = null
    private var selectedWrite: Uri? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "app.auralis/platform").setMethodCallHandler { call, result ->
            when (call.method) {
                "setupStatus" -> {
                    try { result.success(setup.status()) }
                    catch (_: Exception) { result.error("setup_status", "Device settings could not be checked.", null) }
                }
                "setupNotifications" -> setup.notifications(result)
                "setupBattery" -> setup.battery(result)
                "openExternalUrl" -> {
                    try {
                        val uri = android.net.Uri.parse(call.arguments as String)
                        require(uri.scheme == "https" && !uri.host.isNullOrEmpty() && uri.userInfo == null)
                        startActivity(Intent(Intent.ACTION_VIEW, uri))
                        result.success(null)
                    } catch (_: Exception) { result.error("browser", "Could not open the HTTPS link.", null) }
                }
                "updateInfo" -> {
                    try { result.success(updates.info()) }
                    catch (_: Exception) { result.error("update_cache", "Android update cache is unavailable.", null) }
                }
                "installUpdate" -> updates.install(call, result)
                "resetCredentialKey" -> work(result) { vault.reset(); null }
                "encrypt", "decrypt" -> work(result) {
                    val bytes = call.arguments as ByteArray
                    try { if (call.method == "encrypt") vault.encrypt(bytes) else vault.decrypt(bytes) }
                    finally { bytes.fill(0) }
                }
                "createDocument", "openDocument" -> {
                    if (pending != null) result.error("busy", "A file picker is already open.", null)
                    else {
                        val save = call.method == "createDocument"
                        val intent = Intent(if (save) Intent.ACTION_CREATE_DOCUMENT else Intent.ACTION_OPEN_DOCUMENT)
                            .addCategory(Intent.CATEGORY_OPENABLE)
                        intent.type = if (save) call.argument<String>("mime") ?: "application/json" else "*/*"
                        if (save) intent.putExtra(Intent.EXTRA_TITLE, call.argument<String>("name"))
                        try {
                            pending = result
                            startActivityForResult(intent, if (save) 4101 else 4102)
                        } catch (_: Exception) { pending = null; result.error("picker", "No document picker is available.", null) }
                    }
                }
                "readDocument" -> work(result, "document_read") {
                    val uri = Uri.parse(call.argument<String>("uri"))
                    require(uri == selectedRead) { "Choose the file first" }
                    val maxBytes = (call.argument<Number>("maxBytes")?.toInt() ?: (64 * 1024 * 1024))
                    require(maxBytes in 1..(64 * 1024 * 1024)) { "Invalid read limit" }
                    val stream = contentResolver.openInputStream(uri)
                        ?: throw java.io.IOException("Document provider is unavailable")
                    stream.use { input ->
                        val output = java.io.ByteArrayOutputStream()
                        val buffer = ByteArray(64 * 1024)
                        while (true) {
                            val count = input.read(buffer)
                            if (count < 0) break
                            require(output.size().toLong() + count <= maxBytes.toLong()) { "File exceeds size limit" }
                            output.write(buffer, 0, count)
                        }
                        output.toByteArray()
                    }
                }
                "writeDocument" -> work(result) {
                    val uri = Uri.parse(call.argument<String>("uri"))
                    require(uri == selectedWrite) { "Choose the destination first" }
                    val bytes = call.argument<ByteArray>("bytes")!!
                    require(bytes.size <= 64 * 1024 * 1024) { "Export exceeds 64 MiB" }
                    contentResolver.openOutputStream(uri, "wt")!!.use { it.write(bytes); it.flush() }
                    selectedWrite = null
                    null
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun work(result: MethodChannel.Result, operation: String = "storage", action: () -> Any?) {
        io.execute {
            try { val value = action(); runOnUiThread { result.success(value) } }
            catch (error: Exception) {
                val (code, message) = if (operation == "document_read") {
                    when (error) {
                        is SecurityException -> "document_permission" to
                            "Android could not read this backup. Select it again using the system file picker, or copy it to Downloads first."
                        is java.io.FileNotFoundException -> "document_missing" to
                            "The backup is missing or its provider cannot open it. Download it to this device and select it again."
                        is IllegalArgumentException -> "document_invalid" to
                            "${error.message}. Select an Auralis backup no larger than 64 MiB."
                        else -> "document_read" to
                            "The document provider could not read this backup. Download or copy it to Downloads, then select it again."
                    }
                } else {
                    "storage" to "Could not access local storage or the device credential key."
                }
                runOnUiThread { result.error(code, message, null) }
            }
        }
    }

    @Deprecated("Android document activity result bridge")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (updates.onActivityResult(requestCode)) return
        if (requestCode != 4101 && requestCode != 4102) return
        val uri = if (resultCode == Activity.RESULT_OK) data?.data else null
        if (requestCode == 4101) selectedWrite = uri else selectedRead = uri
        pending?.success(uri?.toString())
        pending = null
    }
    override fun onDestroy() {
        pending?.success(null)
        pending = null
        updates.close()
        setup.close()
        io.shutdown()
        super.onDestroy()
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        setup.onPermissionsResult(requestCode)
    }
}
