package com.auralis.siam

import android.app.Activity
import android.media.MediaMetadataRetriever
import android.net.Uri
import androidx.media3.common.Effect
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.Crop
import androidx.media3.effect.Presentation
import androidx.media3.transformer.Composition
import androidx.media3.transformer.DefaultEncoderFactory
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.Effects
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.ProgressHolder
import androidx.media3.transformer.Transformer
import androidx.media3.transformer.VideoEncoderSettings
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executor

@androidx.annotation.OptIn(UnstableApi::class)
internal class VideoExporter(private val activity: Activity, private val io: Executor) {
    private class Job(val output: File, val result: MethodChannel.Result) {
        var transformer: Transformer? = null
    }

    private var active: Job? = null

    fun start(call: MethodCall, result: MethodChannel.Result) {
        if (active != null) {
            result.error("busy", "A video export is already running.", null)
            return
        }
        val uri = Uri.parse(call.argument<String>("source") ?: error("Select a local video"))
        require(uri.scheme == "content")
        val output = outputFile(activity, call.argument<String>("path"))
        require(!output.exists())
        val height = call.argument<Number>("height")?.toInt() ?: 0
        val bitrate = call.argument<Number>("bitrate")?.toInt() ?: 0
        val start = call.argument<Number>("start")?.toLong() ?: 0L
        val end = call.argument<Number>("end")?.toLong()
        val mute = call.argument<Boolean>("mute") == true
        val cropRatio = when (call.argument<String>("crop")) {
            "wide" -> 16f / 9
            "square" -> 1f
            "portrait" -> 9f / 16
            else -> null
        }
        require(height in setOf(0, 480, 720, 1080) && bitrate in 0..12_000_000)
        require(start >= 0 && (end == null || end > start))
        val job = Job(output, result)
        active = job
        io.execute {
            val displayedSize = runCatching {
                val metadata = MediaMetadataRetriever()
                try {
                    metadata.setDataSource(activity, uri)
                    val rotated = metadata.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)
                        .toIntOrZero() in setOf(90, 270)
                    val width = metadata.extractMetadata(
                        MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH,
                    ).toIntOrZero()
                    val sourceHeight = metadata.extractMetadata(
                        MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT,
                    ).toIntOrZero()
                    if (rotated) sourceHeight to width else width to sourceHeight
                } finally {
                    metadata.release()
                }
            }
            activity.runOnUiThread {
                if (active !== job) return@runOnUiThread
                try {
                    val (width, sourceHeight) = displayedSize.getOrThrow()
                    val item = MediaItem.Builder().setUri(uri)
                    if (end != null) {
                        item.setClippingConfiguration(MediaItem.ClippingConfiguration.Builder()
                            .setStartPositionMs(start).setEndPositionMs(end).build())
                    }
                    val effects = mutableListOf<Effect>()
                    var croppedHeight = sourceHeight
                    if (cropRatio != null) {
                        require(width > 1 && sourceHeight > 1) { "Video dimensions are unavailable." }
                        val cropWidth = (minOf(width.toFloat(), sourceHeight * cropRatio)
                            .toInt() / 2 * 2).coerceAtLeast(2)
                        croppedHeight = (minOf(sourceHeight.toFloat(), width / cropRatio)
                            .toInt() / 2 * 2).coerceAtLeast(2)
                        val x = cropWidth.toFloat() / width
                        val y = croppedHeight.toFloat() / sourceHeight
                        effects.add(Crop(-x, x, -y, y))
                    }
                    if (height > 0 && croppedHeight > height) {
                        effects.add(Presentation.createForHeight(height))
                    }
                    val edited = EditedMediaItem.Builder(item.build())
                        .setRemoveAudio(mute).setEffects(Effects(emptyList(), effects)).build()
                    val encoder = DefaultEncoderFactory.Builder(activity).setEnableFallback(true)
                    if (bitrate > 0) encoder.setRequestedVideoEncoderSettings(
                        VideoEncoderSettings.Builder().setBitrate(bitrate).build(),
                    )
                    val transformer = Transformer.Builder(activity)
                        .setEncoderFactory(encoder.build())
                        .setVideoMimeType(MimeTypes.VIDEO_H264)
                        .setAudioMimeType(MimeTypes.AUDIO_AAC)
                        .addListener(object : Transformer.Listener {
                            override fun onCompleted(composition: Composition, exportResult: ExportResult) {
                                finish(job, null)
                            }

                            override fun onError(composition: Composition, exportResult: ExportResult,
                                exportException: ExportException) {
                                finish(job, exportException.message ?: "The device encoder failed.")
                            }
                        }).build()
                    job.transformer = transformer
                    transformer.start(edited, output.path)
                } catch (failure: Exception) {
                    finish(job, failure.message ?: "Could not encode the selected video.")
                }
            }
        }
    }

    fun progress(): Int? {
        val transformer = active?.transformer ?: return null
        val holder = ProgressHolder()
        return if (transformer.getProgress(holder) == Transformer.PROGRESS_STATE_AVAILABLE)
            holder.progress else null
    }

    fun cancel() {
        val job = active ?: return
        active = null
        runCatching { job.transformer?.cancel() }
        job.output.delete()
        job.result.error("cancelled", "Video export cancelled.", null)
    }

    private fun finish(job: Job, error: String?) {
        if (active !== job) return
        active = null
        if (error == null && job.output.length() > 0) {
            job.result.success(null)
        } else {
            job.output.delete()
            job.result.error("video_export", error ?: "The encoder produced an empty file.", null)
        }
    }

    companion object {
        fun outputFile(activity: Activity, path: String?): File {
            val file = File(path ?: error("Missing export path")).canonicalFile
            val parent = file.parentFile ?: error("Missing export directory")
            require(parent.parentFile == activity.cacheDir.canonicalFile &&
                parent.name.startsWith("video-export-") && file.name == "output.mp4")
            return file
        }

        private fun String?.toIntOrZero() = this?.toIntOrNull() ?: 0
    }
}
