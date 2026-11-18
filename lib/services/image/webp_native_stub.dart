import 'dart:typed_data';

/// Web 端没有 FFI，拿不到 libwebp。
///
/// `image` 包只带 webp 解码器、无编码器（ADR-001），Web 端要导出 WebP
/// 只能靠浏览器 `canvas.toBlob('image/webp')`，那是 M4 的事。
bool get webpNativeAvailable => false;

/// 返回 null 表示本端无法编码 WebP。
///
/// [libraryPath] 仅供测试注入；本实现没有原生库，参数保留只为与
/// FFI 版本签名一致（条件导出要求两侧签名相同）。
Uint8List? encodeWebpNative({
  required Uint8List rgba,
  required int width,
  required int height,
  required int quality,
  required bool lossless,
  String? libraryPath,
}) => null;
