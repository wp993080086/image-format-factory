import 'dart:isolate';

import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;

import '../../core/platform/app_platform.dart';
import 'avif_native.dart';

/// AVIF 编解码失败原因。
enum AvifError {
  /// 当前端没有 AVIF 编解码通道（纯 Dart 无 AV1 编解码器）。
  unsupportedPlatform,

  /// 端上有通道，但原生库没就位（当前 Windows 尚未随包 libavif.dll）。
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

/// AVIF 编码器：借平台原生能力，纯 Dart 路线不通（ADR-010 同 WebP/HEIF）。
///
/// 分端策略：
/// - Windows：FFI 调 libavif，需在 [libraryPath] 传入 DLL 路径（测试注入）；
///   仓库当前未随包分发该 DLL，生产启用前需补齐（见 M3 执行手册）。
/// - Android：平台通道，用系统 `ImageDecoder`/`Bitmap` 的 AVIF 能力
///   （Android 11+ 解码 / 部分机型编码），由原生侧实现。
/// - 其余端：不支持。
///
/// [token] 供后台 isolate 发平台消息用，语义同 WebpEncoder。
class AvifCodec {
  AvifCodec._();

  static const channelName = 'pixel_forge/avif';

  /// 指定端是否具备 AVIF 编码能力。
  ///
  /// 能力矩阵据此在 DLL 未就位前隐藏 AVIF 导出，遵循"能力位如实"原则。
  static bool isSupportedFor(AppTarget target) => false;

  static Future<AvifResult> encode({
    required Uint8List rgba,
    required int width,
    required int height,
    required int quality,
    AppTarget? target,
    RootIsolateToken? token,
    String? libraryPath,
  }) async {
    final current = target ?? AppPlatform.current;

    if (current == AppTarget.windows) {
      final bytes = encodeAvifNative(
        rgba: rgba,
        width: width,
        height: height,
        quality: quality,
        libraryPath: libraryPath,
      );
      if (bytes == null) {
        return const AvifResult.failure(AvifError.nativeUnavailable);
      }
      return AvifResult.success(bytes);
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
  /// [maxPixels] 由调用方按端上限传入；[libraryPath] 供测试注入 libavif.dll。
  static Future<AvifDecodeResult> decode(
    Uint8List bytes, {
    required int maxPixels,
    AppTarget? target,
    String? libraryPath,
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
        return const AvifDecodeResult.failure(AvifDecodeError.unsupportedPlatform);
      }
    }

    if (current == AppTarget.windows) {
      final transferable = TransferableTypedData.fromList([bytes]);
      try {
        return await Isolate.run(
          () => _decodeAvifOnWindows(transferable, maxPixels, libraryPath),
        );
      } catch (_) {
        return const AvifDecodeResult.failure(AvifDecodeError.failed);
      }
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

AvifDecodeResult _decodeAvifOnWindows(
  TransferableTypedData transferable,
  int maxPixels,
  String? libraryPath,
) {
  final bytes = transferable.materialize().asUint8List();
  final native = decodeAvifNative(
    bytes,
    maxPixels: maxPixels,
    libraryPath: libraryPath,
  );
  if (!native.isSuccess) {
    return const AvifDecodeResult.failure(AvifDecodeError.failed);
  }
  final image = img.Image.fromBytes(
    width: native.width,
    height: native.height,
    bytes: native.rgba!.buffer,
    numChannels: 4,
    order: img.ChannelOrder.rgba,
  );
  return AvifDecodeResult.success(img.encodePng(image));
}
