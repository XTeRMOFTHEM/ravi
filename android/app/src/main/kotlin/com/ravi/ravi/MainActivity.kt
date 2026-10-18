package com.ravi.ravi

import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream

/// v1.0.9 — native video-frame grabber (replaces the incompatible
/// video_thumbnail plugin). Uses MediaMetadataRetriever to pull a
/// representative frame as JPEG bytes for the chat video tiles.
class MainActivity : FlutterActivity() {
    private val channelName = "ravi/video_frame"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getFrame" -> {
                        val path = call.argument<String>("path") ?: ""
                        val isUrl = call.argument<Boolean>("isUrl") ?: false
                        val maxW = (call.argument<Int>("maxWidth") ?: 480).coerceIn(64, 1280)
                        Thread {
                            try {
                                val r = MediaMetadataRetriever()
                                val bytes: ByteArray?
                                try {
                                    if (isUrl) {
                                        // remote: server needs the session cookie
                                        val cookie = call.argument<String>("cookie") ?: ""
                                        val h = HashMap<String, String>()
                                        if (cookie.isNotEmpty()) h["Cookie"] = cookie
                                        r.setDataSource(path, h)
                                    } else {
                                        r.setDataSource(path)
                                    }
                                    // try a frame at ~1s for a "real" look, fall back to 0
                                    var frame: Bitmap? = r.getFrameAtTime(
                                        900_000,
                                        MediaMetadataRetriever.OPTION_CLOSEST_SYNC
                                    )
                                    if (frame == null) {
                                        frame = r.frameAtTime
                                    }
                                    if (frame != null && frame.width > maxW) {
                                        val ratio = maxW.toFloat() / frame.width
                                        frame = Bitmap.createScaledBitmap(
                                            frame, maxW,
                                            (frame.height * ratio).toInt().coerceAtLeast(1), true
                                        )
                                    }
                                    bytes = frame?.let { bmp ->
                                        val out = ByteArrayOutputStream()
                                        bmp.compress(Bitmap.CompressFormat.JPEG, 72, out)
                                        out.toByteArray()
                                    }
                                } finally {
                                    try { r.release() } catch (_: Exception) {}
                                }
                                if (bytes != null) {
                                    runOnUiThread { result.success(bytes) }
                                } else {
                                    runOnUiThread { result.success(null) }
                                }
                            } catch (e: Exception) {
                                runOnUiThread { result.success(null) }
                            }
                        }.start()
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
