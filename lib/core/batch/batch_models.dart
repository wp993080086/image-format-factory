import 'dart:typed_data';

import '../image/annotation.dart';
import '../image/color_adjust.dart';
import '../image/crop_selection.dart';
import '../image/encode_service.dart';
import '../image/image_format.dart';
import '../image/resize_geometry.dart';
import '../image/watermark.dart';

/// 批量任务配置：一次配置作用于所有输入图（单图 = N=1 的特例）。
class BatchConfig {
  const BatchConfig({
    this.targetFormat = ImageFormat.png,
    this.quality = 85,
    this.icoSizes = const [],
    this.jpegChroma = JpegChromaOption.yuv420,
    this.pngLevel = 6,
    this.pngPalette = false,
    this.exportAnimation = false,
    this.avifQuality = 60,
    this.resize,
    this.circleCrop = false,
    this.crop,
    this.colorAdjust = const ColorAdjust(),
    this.watermark,
    this.annotations = const [],
    this.blur = 0,
    this.targetKb,
  });

  final ImageFormat targetFormat;
  final int quality;
  final List<int> icoSizes;
  final JpegChromaOption jpegChroma;
  final int pngLevel;
  final bool pngPalette;
  final bool exportAnimation;
  final int avifQuality;

  /// 统一尺寸变换；null 保持各图原尺寸。
  final ResizeTarget? resize;

  /// 是否套圆形遮罩（配合 crop）。
  final bool circleCrop;

  /// 统一裁剪区（原图像素坐标）。批量场景一般不用，除非所有图同尺寸。
  final CropArea? crop;

  final ColorAdjust colorAdjust;
  final TextWatermark? watermark;
  final List<Annotation> annotations;
  final int blur;

  /// 按目标体积压缩的目标 KB；null 表示按质量参数直接导出。
  final int? targetKb;

  BatchConfig copyWithTargetFormat(ImageFormat targetFormat) => BatchConfig(
        targetFormat: targetFormat,
        quality: quality,
        icoSizes: icoSizes,
        jpegChroma: jpegChroma,
        pngLevel: pngLevel,
        pngPalette: pngPalette,
        exportAnimation: exportAnimation,
        avifQuality: avifQuality,
        resize: resize,
        circleCrop: circleCrop,
        crop: crop,
        colorAdjust: colorAdjust,
        watermark: watermark,
        annotations: annotations,
        blur: blur,
        targetKb: targetKb,
      );

  BatchConfig copyWith({
    ImageFormat? targetFormat,
    int? quality,
    int? pngLevel,
    bool? pngPalette,
    bool? exportAnimation,
    int? avifQuality,
    bool? circleCrop,
    ColorAdjust? colorAdjust,
    TextWatermark? watermark,
    bool clearWatermark = false,
    List<Annotation>? annotations,
    int? blur,
    int? targetKb,
    bool clearTargetKb = false,
  }) {
    return BatchConfig(
      targetFormat: targetFormat ?? this.targetFormat,
      quality: quality ?? this.quality,
      icoSizes: icoSizes,
      jpegChroma: jpegChroma,
      pngLevel: pngLevel ?? this.pngLevel,
      pngPalette: pngPalette ?? this.pngPalette,
      exportAnimation: exportAnimation ?? this.exportAnimation,
      avifQuality: avifQuality ?? this.avifQuality,
      resize: resize,
      circleCrop: circleCrop ?? this.circleCrop,
      crop: crop,
      colorAdjust: colorAdjust ?? this.colorAdjust,
      watermark: clearWatermark ? null : (watermark ?? this.watermark),
      annotations: annotations ?? this.annotations,
      blur: blur ?? this.blur,
      targetKb: clearTargetKb ? null : (targetKb ?? this.targetKb),
    );
  }
}

/// 批量任务中的单个输入。
class BatchItem {
  const BatchItem({
    required this.id,
    required this.fileName,
    required this.sourceBytes,
    this.animated = false,
  });

  final int id;
  final String fileName;
  final Uint8List sourceBytes;

  /// 源是否为动图（决定 GIF 动图导出是否生效）。
  final bool animated;
}

/// 单个输入的导出结果。
class BatchItemResult {
  const BatchItemResult.success({
    required this.item,
    required this.savedPath,
    required this.outputBytes,
  }) : error = null;
  const BatchItemResult.failure({
    required this.item,
    required this.error,
  }) : savedPath = null, outputBytes = null;

  final BatchItem item;
  final String? savedPath;
  final List<int>? outputBytes;
  final Object? error;

  bool get isSuccess => error == null;
}

/// 批量任务进度快照。
class BatchProgress {
  const BatchProgress({
    required this.done,
    required this.total,
    required this.currentName,
    required this.results,
  });

  final int done;
  final int total;
  final String? currentName;
  final List<BatchItemResult> results;

  double get fraction => total <= 0 ? 0 : done / total;
}
