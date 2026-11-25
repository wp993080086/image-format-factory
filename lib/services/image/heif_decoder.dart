import 'dart:isolate';

import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;

import '../../core/platform/app_platform.dart';
import 'heif_native.dart';

/// HEIF 解码失败原因。
enum HeifDecodeError {
  /// 当前端没有 HEVC 解码能力（纯 Dart 无解码器，仅 Android 8.0+ 与 Windows 有）。
  unsupportedPlatform,

  /// 像素数超过本端上限，拒绝解码以免 OOM。
  pixelLimit,

  /// 容器可识别但解码失败（文件损坏、编码不支持）。
  failed,
}

/// HEIF 解码结果。
class HeifDecodeResult {
  const HeifDecodeResult.success(Uint8List this.png) : error = null;

  const HeifDecodeResult.failure(HeifDecodeError this.error) : png = null;

  /// 解码后的 PNG 字节（成功时非空）。
  ///
  /// 统一转 PNG 而非直接交给 `image` 包：后者没有 HEVC 解码器，
  /// 拿到 HEIC 原始字节只会返回 null，被误判成「文件已损坏」。
  final Uint8List? png;

  final HeifDecodeError? error;

  bool get isSuccess => png != null;
}

/// HEIF（苹果 HEIC / 华为 HEIF）解码：借平台能力，纯 Dart 无解。
///
/// 分端策略：
/// - Android 8.0+：系统自带 HEVC 静态图解码，走 `MethodChannel` 拿 PNG；
/// - Windows：FFI 直调 libheif，解码与 PNG 编码都在子 Isolate 内完成；
/// - 其余端：没有可用通道，返回 [HeifDecodeError.unsupportedPlatform]，
///   由调用方报「暂不支持该格式」——不能报「文件已损坏」，
///   照片本身是好的，坏的是我们的解码能力。
class HeifDecoder {
  HeifDecoder._();

  static const channelName = 'imageformatfactory/heif';

  static const _channel = MethodChannel(channelName);

  /// 当前端是否具备 HEIF 解码能力。
  static bool get isSupported => isSupportedFor(AppPlatform.current);

  /// 指定端是否具备 HEIF 解码能力。
  static bool isSupportedFor(AppTarget target) =>
      target == AppTarget.android || target == AppTarget.windows;

  /// 解码为 PNG 字节。
  ///
  /// [maxPixels] 由调用方按端能力传入；平台侧先取尺寸判定，
  /// 超限直接返回而**不**分配位图。
  /// [target] 仅用于测试注入，生产走 [AppPlatform.current]。
  /// [libraryPath] 仅供测试注入 libheif 的绝对路径。
  static Future<HeifDecodeResult> decode(
    Uint8List bytes, {
    required int maxPixels,
    AppTarget? target,
    String? libraryPath,
  }) async {
    final current = target ?? AppPlatform.current;

    if (current == AppTarget.android) {
      try {
        final png = await _channel.invokeMethod<Uint8List>('decode', {
          'bytes': bytes,
          'maxPixels': maxPixels,
        });
        if (png == null) {
          return const HeifDecodeResult.failure(HeifDecodeError.failed);
        }
        return HeifDecodeResult.success(png);
      } on PlatformException catch (e) {
        return HeifDecodeResult.failure(switch (e.code) {
          'pixel-limit' => HeifDecodeError.pixelLimit,
          'unsupported' => HeifDecodeError.unsupportedPlatform,
          _ => HeifDecodeError.failed,
        });
      } on MissingPluginException {
        // 平台侧未注册通道（旧包/未接入的端），按不支持处理
        return const HeifDecodeResult.failure(
          HeifDecodeError.unsupportedPlatform,
        );
      }
    }

    if (current == AppTarget.windows) {
      // HEVC 解码 + PNG 编码都很慢，放子 Isolate，避免卡住 UI（PRD 八.9）
      final transferable = TransferableTypedData.fromList([bytes]);
      try {
        return await Isolate.run(
          () => _decodeHeifOnWindows(transferable, maxPixels, libraryPath),
        );
      } catch (_) {
        return const HeifDecodeResult.failure(HeifDecodeError.failed);
      }
    }

    return const HeifDecodeResult.failure(
      HeifDecodeError.unsupportedPlatform,
    );
  }
}

/// 子 Isolate 入口：libheif 解码 → PNG 编码。
///
/// 注意：此函数在独立 Isolate 中运行，禁止引用任何 UI / 插件对象。
HeifDecodeResult _decodeHeifOnWindows(
  TransferableTypedData transferable,
  int maxPixels,
  String? libraryPath,
) {
  final bytes = transferable.materialize().asUint8List();
  final native = decodeHeifNative(
    bytes,
    maxPixels: maxPixels,
    libraryPath: libraryPath,
  );
  if (!native.isSuccess) {
    return HeifDecodeResult.failure(
      native.error == HeifNativeError.pixelLimit
          ? HeifDecodeError.pixelLimit
          : HeifDecodeError.failed,
    );
  }
  final rgba = native.rgba!;
  final image = img.Image.fromBytes(
    width: native.width,
    height: native.height,
    bytes: rgba.buffer,
    numChannels: 4,
    order: img.ChannelOrder.rgba,
  );
  return HeifDecodeResult.success(img.encodePng(image));
}
