import 'package:flutter/services.dart';

import '../../core/platform/app_platform.dart';
import 'webp_native.dart';

/// WebP 编码失败原因。
enum WebpEncodeError {
  /// 当前端没有 WebP 编码通道（纯 Dart 无编码器，ADR-001）。
  unsupportedPlatform,

  /// 端上有通道，但原生实现没就位（缺 libwebp / 平台版本过低）。
  nativeUnavailable,

  /// 编码过程失败（像素过大、内存不足等）。
  failed,
}

/// WebP 编码结果。
class WebpEncodeResult {
  const WebpEncodeResult.success(Uint8List this.bytes) : error = null;

  const WebpEncodeResult.failure(WebpEncodeError this.error) : bytes = null;

  final Uint8List? bytes;
  final WebpEncodeError? error;

  bool get isSuccess => bytes != null;
}

/// WebP 编码器：借平台原生能力，纯 Dart 路线不通。
///
/// 分端策略：
/// - Windows：FFI 直调 libwebp（`webp.dll`），在任意 isolate 内都能跑；
/// - Android：平台通道 `Bitmap.compress(WEBP)`，系统自带编解码器，零新增依赖；
/// - 其余端：不支持。
///
/// [token] 是后台 isolate 用的 RootIsolateToken：Android 的通道必须经
/// `BackgroundIsolateBinaryMessenger` 从子 isolate 发起（桌面端 embedder
/// 不支持后台 isolate 发平台消息，所以 Windows 走 FFI 而不是通道）。
class WebpEncoder {
  WebpEncoder._();

  static const channelName = 'imageformatfactory/webp';

  /// 把 RGBA 像素编码为 WebP。
  ///
  /// [rgba] 长度须为 `width * height * 4`；[quality] 为 0–100。
  /// [libraryPath] 仅供测试注入 DLL 绝对路径。
  static Future<WebpEncodeResult> encode({
    required Uint8List rgba,
    required int width,
    required int height,
    required int quality,
    bool lossless = false,
    AppTarget? target,
    RootIsolateToken? token,
    String? libraryPath,
  }) async {
    final current = target ?? AppPlatform.current;

    if (current == AppTarget.windows) {
      final bytes = encodeWebpNative(
        rgba: rgba,
        width: width,
        height: height,
        quality: quality,
        lossless: lossless,
        libraryPath: libraryPath,
      );
      if (bytes == null) {
        return const WebpEncodeResult.failure(WebpEncodeError.nativeUnavailable);
      }
      return WebpEncodeResult.success(bytes);
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
          'lossless': lossless,
        });
        if (bytes == null) {
          return const WebpEncodeResult.failure(WebpEncodeError.failed);
        }
        return WebpEncodeResult.success(bytes);
      } on PlatformException catch (e) {
        return WebpEncodeResult.failure(
          e.code == 'unsupported'
              ? WebpEncodeError.unsupportedPlatform
              : WebpEncodeError.failed,
        );
      } on MissingPluginException {
        return const WebpEncodeResult.failure(WebpEncodeError.unsupportedPlatform);
      }
    }

    return const WebpEncodeResult.failure(WebpEncodeError.unsupportedPlatform);
  }

  /// 子 isolate 内调用时需要后台 messenger；主 isolate 直接用默认通道。
  static BinaryMessenger? _messengerFor(RootIsolateToken? token) {
    if (token == null) return null;
    try {
      BackgroundIsolateBinaryMessenger.ensureInitialized(token);
      return BackgroundIsolateBinaryMessenger.instance;
    } catch (_) {
      // 后台通道不可用（桌面端 embedder 不支持），退回主通道
      return null;
    }
  }
}
