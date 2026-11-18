package com.pixelforge.pixel_forge

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.util.concurrent.Executors

/**
 * 平台原生图像能力通道。
 *
 * 两条通道：
 * - `pixel_forge/heif`：HEIF（苹果 HEIC / 华为 HEIF）解码。
 *   纯 Dart 没有 HEVC 解码器；Android 8.0 起系统自带静态图解码，
 *   这里把 HEIC 字节解成 PNG 字节回给 Dart，后续处理走既有管线。
 * - `pixel_forge/webp`：WebP 编码。
 *   `image` 包只有 webp 解码器；系统自带 WebP 编码器，零新增依赖。
 *
 * 两个通道都在后台线程做重活：解码 12MP 的 HEVC 或压缩大图放主线程会卡 UI，
 * 甚至触发 ANR。结果统一回主线程回调（MethodChannel 要求）。
 */
class MainActivity : FlutterActivity() {
    private val heifChannelName = "pixel_forge/heif"
    private val webpChannelName = "pixel_forge/webp"

    private val worker = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, heifChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "decode" -> decodeHeif(
                        call.argument<ByteArray>("bytes"),
                        call.argument<Int>("maxPixels"),
                        result,
                    )
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, webpChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "encode" -> encodeWebp(
                        call.argument<ByteArray>("rgba"),
                        call.argument<Int>("width"),
                        call.argument<Int>("height"),
                        call.argument<Int>("quality") ?: 85,
                        call.argument<Boolean>("lossless") ?: false,
                        result,
                    )
                    else -> result.notImplemented()
                }
            }
    }

    override fun onDestroy() {
        worker.shutdownNow()
        super.onDestroy()
    }

    private fun decodeHeif(
        bytes: ByteArray?,
        maxPixels: Int?,
        result: MethodChannel.Result,
    ) {
        if (bytes == null || bytes.isEmpty()) {
            result.error("decode-failed", "缺少图片数据", null)
            return
        }
        // HEIF 静态图解码从 Android 8.0（API 26）起由系统提供
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            result.error("unsupported", "系统版本低于 Android 8.0", null)
            return
        }
        worker.execute {
            try {
                // 先只读尺寸：超限时连位图都不分配，避免 OOM 直接杀进程
                val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
                BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
                if (bounds.outWidth <= 0 || bounds.outHeight <= 0) {
                    postError(result, "decode-failed", "无法解析图片尺寸")
                    return@execute
                }
                val pixels = bounds.outWidth.toLong() * bounds.outHeight.toLong()
                if (maxPixels != null && maxPixels > 0 && pixels > maxPixels) {
                    postError(result, "pixel-limit", "$pixels")
                    return@execute
                }
                val bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
                if (bitmap == null) {
                    postError(result, "decode-failed", "解码失败")
                    return@execute
                }
                // 转 PNG：无损且保留透明通道，代价是体积与一次额外解码
                val out = ByteArrayOutputStream()
                bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)
                bitmap.recycle()
                postSuccess(result, out.toByteArray())
            } catch (e: OutOfMemoryError) {
                postError(result, "decode-failed", "内存不足")
            } catch (e: Exception) {
                postError(result, "decode-failed", e.message)
            }
        }
    }

    private fun encodeWebp(
        rgba: ByteArray?,
        width: Int?,
        height: Int?,
        quality: Int,
        lossless: Boolean,
        result: MethodChannel.Result,
    ) {
        if (rgba == null || width == null || height == null || width <= 0 || height <= 0) {
            result.error("encode-failed", "缺少像素数据", null)
            return
        }
        if (rgba.size < width * height * 4) {
            result.error("encode-failed", "像素数据长度不足", null)
            return
        }
        if (lossless) {
            // 系统只有有损 WebP 编码器（Bitmap.CompressFormat.WEBP）
            result.error("unsupported", "系统不支持无损 WebP 编码", null)
            return
        }
        worker.execute {
            try {
                // ARGB_8888 在内存里的字节序就是 R,G,B,A，
                // 传入的 RGBA 可以直接整块拷进位图，不用逐像素转 int
                val bitmap = Bitmap.createBitmap(
                    width,
                    height,
                    Bitmap.Config.ARGB_8888,
                )
                bitmap.copyPixelsFromBuffer(java.nio.ByteBuffer.wrap(rgba))
                val out = ByteArrayOutputStream()
                bitmap.compress(
                    Bitmap.CompressFormat.WEBP,
                    quality.coerceIn(1, 100),
                    out,
                )
                bitmap.recycle()
                postSuccess(result, out.toByteArray())
            } catch (e: OutOfMemoryError) {
                postError(result, "encode-failed", "内存不足")
            } catch (e: Exception) {
                postError(result, "encode-failed", e.message)
            }
        }
    }

    private fun postSuccess(result: MethodChannel.Result, bytes: ByteArray) {
        mainHandler.post { result.success(bytes) }
    }

    private fun postError(result: MethodChannel.Result, code: String, message: String?) {
        mainHandler.post { result.error(code, message, null) }
    }
}
