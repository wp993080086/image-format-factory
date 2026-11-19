import 'dart:typed_data';

/// Web 端没有 FFI，拿不到 libavif。
///
/// `image` 包无 AV1 编解码器，AVIF 只能靠平台原生能力。Web 端签名与
/// FFI 版保持一致，恒返回 false / null。
bool get avifNativeAvailable => false;

Uint8List? encodeAvifNative({
  required Uint8List rgba,
  required int width,
  required int height,
  required int quality,
  String? libraryPath,
}) => null;

/// Web 端无法解码 AVIF，恒返回失败结果。
class AvifNativeDecode {
  const AvifNativeDecode.failed()
    : rgba = null,
      width = 0,
      height = 0,
      error = true;

  final Uint8List? rgba;
  final int width;
  final int height;
  final bool? error;
  bool get isSuccess => rgba != null;
}

AvifNativeDecode decodeAvifNative(
  Uint8List bytes, {
  required int maxPixels,
  String? libraryPath,
}) => const AvifNativeDecode.failed();
