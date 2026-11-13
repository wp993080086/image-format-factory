package com.pixelforge.pixel_forge

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream

/**
 * HEIF（苹果 HEIC / 华为 HEIF）解码通道。
 *
 * 纯 Dart 没有 HEVC 解码器；Android 8.0 起系统自带静态图解码，
 * 这里把 HEIC 字节解成 PNG 字节回给 Dart，后续处理走既有管线。
 */
class MainActivity : FlutterActivity() {
    private val channelName = "pixel_forge/heif"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
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
        try {
            // 先只读尺寸：超限时连位图都不分配，避免 OOM 直接杀进程
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
            if (bounds.outWidth <= 0 || bounds.outHeight <= 0) {
                result.error("decode-failed", "无法解析图片尺寸", null)
                return
            }
            val pixels = bounds.outWidth.toLong() * bounds.outHeight.toLong()
            if (maxPixels != null && maxPixels > 0 && pixels > maxPixels) {
                result.error("pixel-limit", "$pixels", null)
                return
            }
            val bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
            if (bitmap == null) {
                result.error("decode-failed", "解码失败", null)
                return
            }
            // 转 PNG：无损且保留透明通道，代价是体积与一次额外解码
            val out = ByteArrayOutputStream()
            bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)
            bitmap.recycle()
            result.success(out.toByteArray())
        } catch (e: OutOfMemoryError) {
            result.error("decode-failed", "内存不足", null)
        } catch (e: Exception) {
            result.error("decode-failed", e.message, null)
        }
    }
}
