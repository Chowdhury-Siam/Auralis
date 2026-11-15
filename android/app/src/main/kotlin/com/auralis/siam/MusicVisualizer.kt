package com.auralis.siam

import android.Manifest
import android.app.Activity
import android.content.pm.PackageManager
import android.media.audiofx.Visualizer
import android.os.Build
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/** Output waveform only. Never creates AudioRecord or opens a microphone. */
class MusicVisualizer(private val activity: Activity, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "app.auralis/visualizer")
    private var visualizer: Visualizer? = null
    private var pending: MethodChannel.Result? = null
    private var foreground = true
    private var requested = false

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    requested = true
                    if (pending != null) {
                        result.error("busy", "Audio permission is already being requested.", null)
                    } else if (Build.VERSION.SDK_INT >= 23 &&
                        activity.checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
                        pending = result
                        activity.requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), REQUEST)
                    } else start(result)
                }
                "read" -> {
                    val effect = visualizer
                    if (effect == null) result.success(null)
                    else try {
                        val waveform = ByteArray(effect.captureSize)
                        if (effect.getWaveForm(waveform) != Visualizer.SUCCESS) {
                            result.error("capture", "The device could not provide output audio.", null)
                        } else result.success(mapOf("samples" to waveform, "rate" to effect.samplingRate / 1000))
                    } catch (_: Exception) {
                        stop()
                        result.error("capture", "Output audio analysis stopped.", null)
                    }
                }
                "stop" -> { stop(); result.success(null) }
                else -> result.notImplemented()
            }
        }
    }

    private fun start(result: MethodChannel.Result) {
        stop()
        // Permission results can arrive after the user has backgrounded the
        // activity. Dart will explicitly start again when its view resumes.
        if (!foreground) { result.success(null); return }
        try {
            // Session 0 observes the output mix. Android requires RECORD_AUDIO
            // for this effect even though no microphone is recorded.
            val effect = Visualizer(0)
            visualizer = effect
            check(effect.setCaptureSize(minOf(1024, Visualizer.getCaptureSizeRange()[1])) == Visualizer.SUCCESS)
            check(effect.setScalingMode(Visualizer.SCALING_MODE_NORMALIZED) == Visualizer.SUCCESS)
            check(effect.setEnabled(true) == Visualizer.SUCCESS)
            result.success(null)
        } catch (_: Exception) {
            stop()
            result.error("unavailable", "This device does not allow output-audio visualization.", null)
        }
    }

    fun onPermissionsResult(requestCode: Int): Boolean {
        if (requestCode != REQUEST) return false
        val result = pending
        pending = null
        if (result != null) {
            if (Build.VERSION.SDK_INT < 23 ||
                activity.checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) {
                if (requested && foreground) start(result)
                else result.success(null)
            }
            else result.error("permission", "Audio-analysis permission was not granted. Lyrics and playback are unchanged.", null)
        }
        return true
    }

    fun stop() {
        requested = false
        try { visualizer?.release() } catch (_: Exception) {}
        visualizer = null
    }

    fun pause() {
        foreground = false
        stop()
    }

    fun resume() { foreground = true }

    fun close() {
        pending?.error("closed", "The visualizer was closed.", null)
        pending = null
        stop()
        channel.setMethodCallHandler(null)
    }

    companion object { private const val REQUEST = 4190 }
}
