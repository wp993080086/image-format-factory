import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'crop_apply.dart';
import 'crop_selection.dart';
import 'format_detector.dart';
import 'ico_frame_select.dart';
import 'ico_packer.dart';
import 'image_format.dart';
import 'image_header_probe.dart';

/// 编码请求。
class EncodeRequest {
  const EncodeRequest({
    required this.sourceBytes,
    required this.format,
    this.quality = 85,
    this.icoSizes = const [],
    this.crop,
    this.cropCircle = false,
  });

  /// 源文件字节流（会话期缓存，导出时据此二次解码全图，PRD 九.3 延迟渲染）。
  final Uint8List sourceBytes;

  /// 目标格式，须在 [EncodeService.exportableFormats] 内。
  final ImageFormat format;

  /// 质量 1–100，仅 JPEG 有意义（PRD 九.4 默认 85）。
  final int quality;

  /// ICO 打包尺寸，仅 [ImageFormat.ico] 有意义；为空时取全部可生成尺寸。
  final List<int> icoSizes;

  /// 裁剪区（原图像素坐标）；null 表示不裁剪。裁剪与编码在同一次解码内完成，
  /// 不产生中间文件（PRD 二章注 / 四章「一次编码」）。
  final CropArea? crop;

  /// 是否按圆形遮罩输出（PRD 二.7：方形画布 + 圆外透明）。
  final bool cropCircle;
}

/// 编码结果。
class EncodeResult {
  const EncodeResult({
    required this.bytes,
    required this.size,
    required this.alphaFlattened,
  });

  final Uint8List bytes;

  /// 输出图像尺寸。
  final ImageDimensions size;

  /// 是否因目标格式不支持 Alpha 而做了透明填底（PRD 四.4 / 四.6），供 UI 提示。
  final bool alphaFlattened;
}

/// 图片编码服务：在独立 Isolate 中二次解码全图并编码为导出格式。
///
/// 对应 PRD 九.3 延迟渲染（导出时从源字节流重新解码）与八.9（编解码不占主 Isolate）。
class EncodeService {
  const EncodeService();

  /// 当前可导出的格式。
  ///
  /// 不含 WebP：`image` 包无编码器（ADR-001），与端能力矩阵取交集后才呈现
  /// 在导出面板。
  static const exportableFormats = <ImageFormat>[
    ImageFormat.jpeg,
    ImageFormat.png,
    ImageFormat.bmp,
    ImageFormat.ico,
  ];

  /// 编码 [EncodeRequest.sourceBytes] 为目标格式。
  ///
  /// 解码失败、格式不支持或 ICO 无可用尺寸时返回 null（由调用方转为
  /// `E-EXPORT-006`）。
  Future<EncodeResult?> encode(EncodeRequest request) {
    // 零拷贝传入子 Isolate（PRD 八.9）
    final transferable = TransferableTypedData.fromList([request.sourceBytes]);
    return Isolate.run(
      () => _encodeImage(
        transferable,
        request.format,
        request.quality,
        request.icoSizes,
        request.crop,
        request.cropCircle,
      ),
    );
  }
}

/// 子 Isolate 入口：解码全图 → 校正方向 → 裁剪 → 按需填底 → 编码。
///
/// 注意：此函数在独立 Isolate 中运行，禁止引用任何 UI / 插件对象。
EncodeResult? _encodeImage(
  TransferableTypedData transferable,
  ImageFormat format,
  int quality,
  List<int> icoSizes,
  CropArea? crop,
  bool cropCircle,
) {
  final source = transferable.materialize().asUint8List();
  final decoded = img.decodeImage(source);
  if (decoded == null) return null;

  // ICO 是多尺寸容器，取像素数最大的那一帧（PRD 4.1）；其余格式保持原样
  final bitmap = ImageFormatDetector.isIco(source)
      ? largestIcoFrame(decoded)
      : decoded;

  // 方向在解码时烘焙，不写入导出（PRD 八.6，避免二次旋转）
  final oriented = img.bakeOrientation(bitmap);

  // 裁剪作用于原图全分辨率位图，先于所有导出处理（PRD 二章注：直接像素拷贝）
  var work = oriented;
  if (crop != null && !crop.isEmpty) {
    work = applyCrop(oriented, crop, circle: cropCircle);
  }

  if (format == ImageFormat.ico) {
    // ICO 是多尺寸容器：每个尺寸独立重采样后打包为单文件（PRD 一.4）
    final packed = packIco(
      work,
      icoSizes.isEmpty
          ? defaultIcoSizes(width: work.width, height: work.height)
          : icoSizes,
    );
    if (packed == null) return null;
    final largest = packed.sizes.last;
    return EncodeResult(
      bytes: packed.bytes,
      size: ImageDimensions(largest, largest),
      alphaFlattened: false,
    );
  }

  var output = work;
  var alphaFlattened = false;
  if (!format.supportsAlpha && work.hasAlpha) {
    // 目标不支持 Alpha：透明区域填白底后合成（PRD 四.4 / 四.6）
    final background = img.Image(
      width: work.width,
      height: work.height,
      numChannels: 3,
    );
    img.fill(background, color: img.ColorRgb8(255, 255, 255));
    img.compositeImage(background, work);
    output = background;
    alphaFlattened = true;
  }

  final bytes = switch (format) {
    // 注意：encodeJpg 默认色度抽样是 yuv444，PRD 九.4 要求默认 4:2:0，故显式传入
    ImageFormat.jpeg => img.encodeJpg(
      output,
      quality: quality.clamp(1, 100),
      chroma: img.JpegChroma.yuv420,
    ),
    ImageFormat.png => img.encodePng(output),
    ImageFormat.bmp => img.encodeBmp(output),
    _ => null,
  };
  if (bytes == null) return null;

  return EncodeResult(
    bytes: bytes,
    size: ImageDimensions(output.width, output.height),
    alphaFlattened: alphaFlattened,
  );
}
