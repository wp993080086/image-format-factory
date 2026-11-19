import 'package:flutter/services.dart';

import '../../core/platform/app_platform.dart';
import 'avif_cli.dart';

/// AVIF 编解码失败原因。
enum AvifError {
  /// 当前端没有 AVIF 编解码通道（纯 Dart 无 AV1 编解码器）。
  unsupportedPlatform,

  /// 端上有通道，但随包 CLI 未就位。
  nativeUnavailable,

  /// 编码过程失败。
  failed,
}

/// AVIF 编码结果。
class AvifResult {
  const AvifResult.success(Uint8List this.bytes) : error = null;
  const AvifResult.failure(AvifError this.error) : bytes = null;

  final Uint8List? bytes;
  final AvifError? error;

  bool get isSuccess => bytes != null;
}

/// AVIF 解码失败原因。
enum AvifDecodeError {
  unsupportedPlatform,
  pixelLimit,
  failed,
}

/// AVIF 解码结果（统一转 PNG 后进入既有管线，同 HeifDecodeResult）。
class AvifDecodeResult {
  const AvifDecodeResult.success(Uint8List this.png) : error = null;
  const AvifDecodeResult.failure(AvifDecodeError this.error) : png = null;

  final Uint8List? png;
  final AvifDecodeError? error;

  bool get isSuccess => png != null;
}

/// AVIF 编码器：纯 Dart 无 AV1 编解码器，借平台原生能力（同 WebP/HEIF）。
///
/// 分端策略：
/// - Windows：调随包的 libavif 官方 CLI（avifenc/avifdec），静态链接零依赖；
///   [exeDir] 供测试注入 CLI 所在目录。
/// - Android：平台通道，用系统 ImageDecoder 的 AVIF 静态图解码
///   （Android 12+/部分 11 机型）；编码系统无 API，返回 unsupported。
/// - 其余端：不支持。
///
/// [token] 供后台 isolate 发平台消息用，语义同 WebpEncoder。
class AvifCodec {
  AvifCodec._();

  static const channelName = 'pixel_forge/avif';

  /// 指定端是否具备 AVIF 能力（编码 Windows 可，Android 仅解码）。
  static bool isSupportedFor(AppTarget target) =>
      target == AppTarget.windows || target == AppTarget.android;

  /// 指定端是否具备 AVIF 编码能力（Android 系统无 AVIF 编码器）。
  static bool canEncodeFor(AppTarget target) => target == AppTarget.windows;

  static Future<AvifResult> encode({
    required Uint8List rgba,
    required int width,
    required int height,
    required int quality,
    AppTarget? target,
    RootIsolateToken? token,
    String? exeDir,
  }) async {
    final current = target ?? AppPlatform.current;

    if (current == AppTarget.windows) {
      final result = await encodeAvifCli(
        rgba: rgba,
        width: width,
        height: height,
        quality: quality,
        exeDir: exeDir,
      );
      if (!result.isSuccess) {
        return AvifResult.failure(
          result.error == 'avifenc.exe not found'
              ? AvifError.nativeUnavailable
              : AvifError.failed,
        );
      }
      return AvifResult.success(result.bytes!);
    }

    if (current == AppTarget.android) {
      try {
        final channel = MethodChannel(
          channelName,
          const StandardMethodCodec(),
          _messengerFor(token),
        );
        final bytes = await channel.invokeMethod<Uint8List>('encode', {
          'rgba': rgba,
          'width': width,
          'height': height,
          'quality': quality,
        });
        if (bytes == null) {
          return const AvifResult.failure(AvifError.failed);
        }
        return AvifResult.success(bytes);
      } on PlatformException catch (e) {
        return AvifResult.failure(
          e.code == 'unsupported'
              ? AvifError.unsupportedPlatform
              : AvifError.failed,
        );
      } on MissingPluginException {
        return const AvifResult.failure(AvifError.unsupportedPlatform);
      }
    }

    return const AvifResult.failure(AvifError.unsupportedPlatform);
  }

  /// 解码 AVIF 为 PNG 字节。
  ///
  /// [maxPixels] 由调用方按端上限传入；[exeDir] 供测试注入 Windows CLI 目录。
  static Future<AvifDecodeResult> decode(
    Uint8List bytes, {
    required int maxPixels,
    AppTarget? target,
    String? exeDir,
  }) async {
    final current = target ?? AppPlatform.current;

    if (current == AppTarget.android) {
      try {
        const channel = MethodChannel(channelName);
        final png = await channel.invokeMethod<Uint8List>('decode', {
          'bytes': bytes,
          'maxPixels': maxPixels,
        });
        if (png == null) {
          return const AvifDecodeResult.failure(AvifDecodeError.failed);
        }
        return AvifDecodeResult.success(png);
      } on PlatformException catch (e) {
        return AvifDecodeResult.failure(switch (e.code) {
          'pixel-limit' => AvifDecodeError.pixelLimit,
          'unsupported' => AvifDecodeError.unsupportedPlatform,
          _ => AvifDecodeError.failed,
        });
      } on MissingPluginException {
        return const AvifDecodeResult.failure(
          AvifDecodeError.unsupportedPlatform,
        );
      }
    }

    if (current == AppTarget.windows) {
      final result = await decodeAvifCli(
        bytes,
        maxPixels: maxPixels,
        exeDir: exeDir,
      );
      if (!result.isSuccess) {
        return const AvifDecodeResult.failure(AvifDecodeError.failed);
      }
      return AvifDecodeResult.success(result.bytes!);
    }

    return const AvifDecodeResult.failure(AvifDecodeError.unsupportedPlatform);
  }

  static BinaryMessenger? _messengerFor(RootIsolateToken? token) {
    if (token == null) return null;
    try {
      BackgroundIsolateBinaryMessenger.ensureInitialized(token);
      return BackgroundIsolateBinaryMessenger.instance;
    } catch (_) {
      return null;
    }
  }
}
