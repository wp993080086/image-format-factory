import 'dart:typed_data';

/// HEIF 原生解码的错误分类。
enum HeifNativeError {
  /// 像素数超过本端上限，解码前就被拦下（连位图都不分配）。
  pixelLimit,

  /// 容器可识别但解码失败：文件损坏、编码不支持、原生库缺失。
  failed,
}

/// HEIF 原生解码结果。
class HeifNativeDecode {
  const HeifNativeDecode.success(this.rgba, this.width, this.height)
    : error = null;

  const HeifNativeDecode.pixelLimit()
    : rgba = null,
      width = 0,
      height = 0,
      error = HeifNativeError.pixelLimit;

  const HeifNativeDecode.failed()
    : rgba = null,
      width = 0,
      height = 0,
      error = HeifNativeError.failed;

  /// 解码后的 RGBA 像素（成功时非空）。
  final Uint8List? rgba;

  final int width;
  final int height;

  final HeifNativeError? error;

  bool get isSuccess => rgba != null;
}
