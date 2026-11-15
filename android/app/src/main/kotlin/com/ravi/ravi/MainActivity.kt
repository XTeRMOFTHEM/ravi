package com.ravi.ravi

import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.net.Uri
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/// Native video-frame grabber backed by MediaMetadataRetriever.
/// Hardened: bounded worker pool (no thread explosion), strict same-origin
/// cookie gating (never sends session cookie to third-party hosts), and
/// deterministic Bitmap recycling to avoid native heap leaks.
class MainActivity : FlutterActivity() {
    private val channelName = "ravi/video_frame"
    private val frameExecutor: ExecutorService = Executors.newFixedThreadPool(3)

    private fun isSameOrigin(url: String, allowedHost: String): Boolean {
        if (allowedHost.isBlank()) return false
        return try {
            val parsed = Uri.parse(url)
            val scheme = parsed.scheme?.lowercase() ?: return false
            if (scheme != "http" && scheme != "https") return false
            val host = parsed.host?.lowercase() ?: return false
            host == allowedHost.lowercase()
        } catch (_: Exception) {
            false
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getFrame" -> {
                        val path = call.argument<String>("path") ?: ""
                        val isUrl = call.argument<Boolean>("isUrl") ?: false
                        val cookie = call.argument<String>("cookie") ?: ""
                        val allowedHost = call.argument<String>("allowedHost") ?: ""
                        val maxW = (call.argument<Int>("maxWidth") ?: 480).coerceIn(64, 1280)
                        if (path.isBlank()) {
                            result.success(null)
                            return@setMethodCallHandler
                        }
                        frameExecutor.execute {
                            val bytes: ByteArray? = extractFrame(path, isUrl, cookie, allowedHost, maxW)
                            runOnUiThread {
                                try {
                                    result.success(bytes)
                                } catch (_: Exception) {
                                }
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun extractFrame(
        path: String,
        isUrl: Boolean,
        cookie: String,
        allowedHost: String,
        maxW: Int
    ): ByteArray? {
        val retriever = MediaMetadataRetriever()
        var frame: Bitmap? = null
        var scaled: Bitmap? = null
        return try {
            if (isUrl) {
                val headers = HashMap<String, String>()
                if (cookie.isNotEmpty() && isSameOrigin(path, allowedHost)) {
                    headers["Cookie"] = cookie
                }
                retriever.setDataSource(path, headers)
            } else {
                retriever.setDataSource(path)
            }
            frame = retriever.getFrameAtTime(
                900_000,
                MediaMetadataRetriever.OPTION_CLOSEST_SYNC
            ) ?: retriever.frameAtTime

            val target: Bitmap? = if (frame != null && frame.width > maxW) {
                val ratio = maxW.toFloat() / frame.width
                scaled = Bitmap.createScaledBitmap(
                    frame,
                    maxW,
                    (frame.height * ratio).toInt().coerceAtLeast(1),
                    true
                )
                scaled
            } else {
                frame
            }

            target?.let { bmp ->
                val out = ByteArrayOutputStream()
                bmp.compress(Bitmap.CompressFormat.JPEG, 72, out)
                out.toByteArray()
            }
        } catch (_: Exception) {
            null
        } finally {
            try {
                if (scaled != null && scaled !== frame && !scaled.isRecycled) {
                    scaled.recycle()
                }
                if (frame != null && !frame.isRecycled) {
                    frame.recycle()
                }
            } catch (_: Exception) {
            }
            try {
                retriever.release()
            } catch (_: Exception) {
            }
        }
    }

    override fun onDestroy() {
        frameExecutor.shutdownNow()
        super.onDestroy()
    }
}
