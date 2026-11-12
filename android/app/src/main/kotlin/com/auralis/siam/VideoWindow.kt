package com.auralis.siam

import android.annotation.TargetApi
import android.app.Activity
import android.app.PendingIntent
import android.app.PictureInPictureParams
import android.app.RemoteAction
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.graphics.drawable.Icon
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import android.util.Rational
import android.view.WindowManager
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executor
import kotlin.math.abs
import kotlin.math.roundToInt

internal class VideoWindow(
    private val activity: Activity,
    messenger: BinaryMessenger,
    private val io: Executor,
) {
    companion object {
        private const val OPEN_FILES = 4103
    }

    private val channel = MethodChannel(messenger, "app.auralis/video")
    private val documents = VideoDocuments(activity, messenger, io)
    private val toggleAction = "${activity.packageName}.VIDEO_PIP_TOGGLE"
    private var picker: MethodChannel.Result? = null
    private var autoPip = false
    private var immersive = false
    private var previousSystemBarsBehavior: Int? = null
    private var playing = false
    private var closed = false
    private var aspect = Rational(16, 9)
    private val supported =
        Build.VERSION.SDK_INT >= 26 &&
            activity.packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)

    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action == toggleAction && activity.isInPictureInPictureMode) {
                channel.invokeMethod("togglePlayback", null)
            }
        }
    }

    init {
        if (supported) {
            val filter = IntentFilter(toggleAction)
            if (Build.VERSION.SDK_INT >= 33) {
                activity.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
            } else {
                @Suppress("DEPRECATION")
                activity.registerReceiver(receiver, filter)
            }
        }
        channel.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "openFiles" -> openFiles(result)
                    "immersiveMode" -> {
                        immersive = call.arguments == true
                        updateSystemBars()
                        result.success(null)
                    }
                    "matchRefreshRate" -> {
                        matchRefreshRate((call.arguments as? Number)?.toDouble())
                        result.success(null)
                    }
                    "autoPip" -> {
                        autoPip = call.argument<Boolean>("auto") == true
                        playing = call.argument<Boolean>("playing") == true
                        val width = call.argument<Number>("width")?.toInt() ?: 0
                        val height = call.argument<Number>("height")?.toInt() ?: 0
                        val ratio = if (height > 0) width.toDouble() / height else 0.0
                        if (ratio in (1.0 / 2.39)..2.39) aspect = Rational(width, height)
                        if (Build.VERSION.SDK_INT >= 26 && supported) {
                            activity.setPictureInPictureParams(params())
                        }
                        result.success(null)
                    }
                    "pictureInPicture" -> result.success(enterPip())
                    "getBrightness" -> result.success(brightness())
                    "thermalHeadroom" -> {
                        val headroom = if (Build.VERSION.SDK_INT >= 30) {
                            activity.getSystemService(PowerManager::class.java)?.getThermalHeadroom(0)
                        } else null
                        result.success(headroom?.takeIf { it.isFinite() }?.toDouble())
                    }
                    "brightness" -> {
                        val value = (call.arguments as? Number)?.toFloat()
                        val attributes = activity.window.attributes
                        attributes.screenBrightness = value?.coerceIn(.01f, 1f)
                            ?: WindowManager.LayoutParams.BRIGHTNESS_OVERRIDE_NONE
                        activity.window.attributes = attributes
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            } catch (_: Exception) {
                result.error("video_window", "Android could not complete the video action.", null)
            }
        }
    }

    fun onIntent(intent: Intent) {
        runCatching { documents.accept(intent) }
    }

    @Suppress("DEPRECATION")
    private fun matchRefreshRate(fps: Double?) {
        val display = if (Build.VERSION.SDK_INT >= 30) activity.display else activity.windowManager.defaultDisplay
        val mode = display?.mode
        val requested = if (display == null || mode == null || fps == null || !fps.isFinite() || fps !in 12.0..144.0) null else {
            display.supportedModes.filter { candidate ->
                val multiple = (candidate.refreshRate / fps).roundToInt()
                candidate.physicalWidth == mode.physicalWidth &&
                    candidate.physicalHeight == mode.physicalHeight &&
                    multiple >= 1 && abs(candidate.refreshRate - fps * multiple) <= 0.2
            }.minByOrNull { it.refreshRate }
        }
        val attributes = activity.window.attributes
        val id = requested?.modeId ?: 0
        if (attributes.preferredDisplayModeId != id) {
            attributes.preferredDisplayModeId = id
            activity.window.attributes = attributes
        }
    }

    private fun brightness(): Double {
        val current = activity.window.attributes.screenBrightness
        if (current >= 0) return current.toDouble()
        return Settings.System.getInt(
            activity.contentResolver, Settings.System.SCREEN_BRIGHTNESS, 128
        ).toDouble() / 255.0
    }

    @TargetApi(26)
    private fun params(): PictureInPictureParams {
        val description = if (playing) "Pause video" else "Play video"
        val toggle = RemoteAction(
            Icon.createWithResource(
                activity,
                if (playing) android.R.drawable.ic_media_pause else android.R.drawable.ic_media_play,
            ),
            description,
            description,
            PendingIntent.getBroadcast(
                activity,
                4104,
                Intent(toggleAction).setPackage(activity.packageName),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            ),
        )
        return PictureInPictureParams.Builder()
            .setAspectRatio(aspect)
            .setActions(listOf(toggle))
            .apply {
                if (Build.VERSION.SDK_INT >= 31) {
                    setAutoEnterEnabled(autoPip && playing)
                    setSeamlessResizeEnabled(true)
                }
            }
            .build()
    }

    private fun enterPip(): Boolean =
        Build.VERSION.SDK_INT >= 26 && supported &&
            (activity.isInPictureInPictureMode || activity.enterPictureInPictureMode(params()))

    fun onUserLeave() {
        if (Build.VERSION.SDK_INT in 26..30 && supported && autoPip && playing) {
            runCatching { enterPip() }
        }
    }

    fun onPipChanged(enabled: Boolean) {
        updateSystemBars()
        channel.invokeMethod("pipChanged", enabled)
    }

    fun onWindowFocused() {
        if (immersive) updateSystemBars()
    }

    private fun updateSystemBars() {
        val inPip = Build.VERSION.SDK_INT >= 26 && activity.isInPictureInPictureMode
        val window = activity.window
        val controller = WindowCompat.getInsetsController(window, window.decorView)
        val systemBars = WindowInsetsCompat.Type.systemBars()
        if (immersive && !inPip) {
            if (previousSystemBarsBehavior == null) {
                previousSystemBarsBehavior = controller.systemBarsBehavior
            }
            controller.systemBarsBehavior =
                WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            controller.hide(systemBars)
        } else if (previousSystemBarsBehavior != null) {
            controller.show(systemBars)
            previousSystemBarsBehavior?.let { controller.systemBarsBehavior = it }
            previousSystemBarsBehavior = null
        }
    }

    private fun openFiles(result: MethodChannel.Result) {
        if (picker != null) {
            result.error("busy", "A file picker is already open.", null)
            return
        }
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT)
            .addCategory(Intent.CATEGORY_OPENABLE)
            .setType("video/*")
            .putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
        picker = result
        try {
            @Suppress("DEPRECATION")
            activity.startActivityForResult(intent, OPEN_FILES)
        } catch (error: Exception) {
            picker = null
            throw error
        }
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != OPEN_FILES) return false
        val callback = picker ?: return true
        if (resultCode != Activity.RESULT_OK || data == null) {
            picker = null
            callback.success(emptyList<Map<String, String>>())
            return true
        }
        val uris = VideoDocuments.intentFiles(data)
        io.execute {
            if (data.flags and Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION != 0) {
                for (uri in uris) runCatching {
                    activity.contentResolver.takePersistableUriPermission(
                        uri, Intent.FLAG_GRANT_READ_URI_PERMISSION,
                    )
                }
            }
            val files = documents.describe(uris)
            activity.runOnUiThread {
                if (!closed && picker === callback) {
                    picker = null
                    callback.success(files)
                }
            }
        }
        return true
    }

    fun close() {
        closed = true
        immersive = false
        updateSystemBars()
        documents.close()
        if (supported) activity.unregisterReceiver(receiver)
        picker?.success(null)
        picker = null
        channel.setMethodCallHandler(null)
    }
}
