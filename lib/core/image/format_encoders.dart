import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'image_format.dart';

/// v0.5 / M3 新增的纯 Dart 格式编解码（TIFF 双向、GIF 动图导出）。
///
/// 这些格式的编解码 `image` 包已内置，不需要平台通道，因此在任意 isolate
/// 里都能调用。`encode_service.dart` 通过本文件把它们接入统一导出链路。
///
/// AVIF 不在此列——它没有纯 Dart 实现，走 services/image/avif_codec.dart
/// 的平台通道/FFI。
class FormatEncoders {
  FormatEncoders._();

  /// 该格式能否由纯 Dart 编码（不含 WebP/AVIF/ICO 这些特殊通道）。
  static bool canEncode(ImageFormat format) =>
      format == ImageFormat.tiff ||
      format == ImageFormat.gif ||
      format == ImageFormat.bmp;

  /// TIFF 编码：单帧，保留 Alpha（TIFF 支持 RGBA）。
  ///
  /// 多页 TIFF 的导入由解码侧取第 1 页，导出统一写单页——比照 PRD 的约定。
  static Uint8List encodeTiff(img.Image image) => img.encodeTiff(image);

  /// GIF 编码。
  ///
  /// [frames] 为 null 时输出静态 GIF（单帧）；非空时输出动图，帧序与
  /// 每帧时长（百分之一秒）由 [GifFrame] 携带，循环次数 [loopCount]（0=无限）。
  ///
  /// 帧内容不做修改（PRD v0.5：GIF 只做帧序/延时/播放次数的重导出，
  /// 不做逐帧编辑）。GIF 调色板最多 256 色，编码阶段量化，属格式固有限制。
  static Uint8List encodeGif(
    img.Image firstFrame, {
    List<GifFrame>? frames,
    int loopCount = 0,
  }) {
    if (frames == null || frames.isEmpty) {
      return img.encodeGif(firstFrame, singleFrame: true, repeat: loopCount);
    }

    // 第一帧本身就是容器（新建空 Image 会多出一帧），从它复制一份避免
    // 修改调用方传入的对象；帧时长写进每帧的 frameDuration。
    // image 包的 frameDuration 单位是毫秒，GIF 文件里存的是 1/100 秒，
    // 编码时库会除以 10，所以这里把厘秒 ×10 还原成毫秒。
    final animation = img.Image.from(firstFrame);
    animation.frameDuration = frames.first.durationCentiseconds * 10;
    for (var i = 1; i < frames.length; i++) {
      final frame = img.Image.from(frames[i].image);
      frame.frameDuration = frames[i].durationCentiseconds * 10;
      animation.addFrame(frame);
    }
    animation.loopCount = loopCount;
    return img.encodeGif(animation, repeat: loopCount);
  }
}

/// GIF 单帧：位图 + 时长（单位：百分之一秒，遵循 GIF 规范）。
class GifFrame {
  const GifFrame({
    required this.image,
    required this.durationCentiseconds,
  });

  final img.Image image;

  /// 显示时长，1 = 10ms。0 在 GIF 规范里表示"未指定"，编码器会按需兜底。
  final int durationCentiseconds;
}
