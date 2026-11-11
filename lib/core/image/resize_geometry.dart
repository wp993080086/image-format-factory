import 'dart:math' as math;

import 'crop_selection.dart';
import 'image_header_probe.dart';

/// 放大上限：目标边长不超过原图对应边的 4 倍（PRD 三.1）。
const int maxResizeUpscale = 4;

/// 目标总像素上限：4000 万（PRD 三.1）。
const int maxResizePixels = 40000000;

/// 尺寸与比例变换的填充方式（PRD 三.2）。
enum ResizeMode {
  stretch('拉伸填充', '不保持比例，强制拉伸填满目标尺寸'),
  cover('裁剪填充', '保持比例填满目标框，居中裁掉超出部分'),
  contain('留白填充', '保持比例缩进目标框，空白处补底色');

  const ResizeMode(this.label, this.description);

  final String label;

  /// 面板上的一句话说明。
  final String description;
}

/// 目标尺寸与填充方式。
class ResizeTarget {
  const ResizeTarget({
    required this.width,
    required this.height,
    this.mode = ResizeMode.stretch,
    this.backgroundArgb = transparentBackground,
  });

  /// 留白底色为全透明（ARGB 最高字节为 0）。
  static const int transparentBackground = 0x00000000;

  final int width;
  final int height;
  final ResizeMode mode;

  /// contain 模式的留白底色，ARGB；[transparentBackground] 表示留白透明。
  ///
  /// 仅 [ResizeMode.contain] 使用：stretch 铺满目标框、cover 裁掉多余部分，
  /// 都不产生留白。
  final int backgroundArgb;

  bool get isTransparent => (backgroundArgb >> 24) & 0xFF == 0;

  /// 与 [source] 相比是否真的改变了尺寸。
  ///
  /// 尺寸相同即视为不变——三种模式在目标框与源图同尺寸时结果一致，
  /// 没有必要为此多走一次重采样。
  bool differsFrom(ImageDimensions source) =>
      width != source.width || height != source.height;

  ResizeTarget copyWith({
    int? width,
    int? height,
    ResizeMode? mode,
    int? backgroundArgb,
  }) {
    return ResizeTarget(
      width: width ?? this.width,
      height: height ?? this.height,
      mode: mode ?? this.mode,
      backgroundArgb: backgroundArgb ?? this.backgroundArgb,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ResizeTarget &&
      other.width == width &&
      other.height == height &&
      other.mode == mode &&
      other.backgroundArgb == backgroundArgb;

  @override
  int get hashCode => Object.hash(width, height, mode, backgroundArgb);

  @override
  String toString() => 'ResizeTarget(${width}x$height, ${mode.name})';
}

/// 钳制结果：实际生效尺寸 + 是否被哪条上限拦下。
class ResizeClamp {
  const ResizeClamp({
    required this.width,
    required this.height,
    this.edgeLimited = false,
    this.pixelsLimited = false,
  });

  final int width;
  final int height;

  /// 单边超过「原图对应边 × 4」而被截断。
  final bool edgeLimited;

  /// 总像素超过 4000 万而被等比缩小。
  final bool pixelsLimited;

  bool get clamped => edgeLimited || pixelsLimited;
}

/// 应用 PRD 三.1 的双上限。
///
/// 顺序很重要：先按边长截断，再按总像素等比缩小。反过来会在边长已经合法、
/// 像素仍超限时留下一个仍超边长的结果。
ResizeClamp clampResizeTarget(ImageDimensions source, int width, int height) {
  final maxWidth = math.max(1, source.width * maxResizeUpscale);
  final maxHeight = math.max(1, source.height * maxResizeUpscale);
  var w = width.clamp(1, maxWidth);
  var h = height.clamp(1, maxHeight);
  final edgeLimited = w != width || h != height;

  var pixelsLimited = false;
  if (w * h > maxResizePixels) {
    // 等比缩到刚好满足总像素上限，floor 保证结果不再超限
    final scale = math.sqrt(maxResizePixels / (w * h));
    w = math.max(1, (w * scale).floor());
    h = math.max(1, (h * scale).floor());
    pixelsLimited = true;
  }

  return ResizeClamp(
    width: w,
    height: h,
    edgeLimited: edgeLimited,
    pixelsLimited: pixelsLimited,
  );
}

/// cover 模式下需要从源图裁出的区域（源像素坐标），保持目标宽高比。
///
/// 缩放系数取 `max(目标宽/源宽, 目标高/源高)`，即短边先填满；裁切居中。
CropArea coverSourceRect(
  ImageDimensions source,
  int targetWidth,
  int targetHeight,
) {
  final scale = math.max(
    targetWidth / source.width,
    targetHeight / source.height,
  );
  final cropW = math.min(
    source.width,
    math.max(1, (targetWidth / scale).round()),
  );
  final cropH = math.min(
    source.height,
    math.max(1, (targetHeight / scale).round()),
  );
  return CropArea(
    x: (source.width - cropW) ~/ 2,
    y: (source.height - cropH) ~/ 2,
    width: cropW,
    height: cropH,
  );
}

/// contain 模式下的内容尺寸与居中偏移。
class ContainedLayout {
  const ContainedLayout({
    required this.width,
    required this.height,
    required this.dx,
    required this.dy,
  });

  /// 内容缩放后的尺寸。
  final int width;
  final int height;

  /// 内容在目标画布中的左上角偏移。
  final int dx;
  final int dy;
}

/// 计算 contain 模式的内嵌布局：等比缩到能装进目标框，居中放置。
ContainedLayout containLayout(
  ImageDimensions source,
  int targetWidth,
  int targetHeight,
) {
  final scale = math.min(
    targetWidth / source.width,
    targetHeight / source.height,
  );
  final w = math.max(1, (source.width * scale).round());
  final h = math.max(1, (source.height * scale).round());
  return ContainedLayout(
    width: math.min(w, targetWidth),
    height: math.min(h, targetHeight),
    dx: math.max(0, (targetWidth - w) ~/ 2),
    dy: math.max(0, (targetHeight - h) ~/ 2),
  );
}

/// 缩放倍率的展示文案：`50%` / `200%`。
String scaleLabel(ImageDimensions source, int targetWidth, int targetHeight) {
  final ratio = targetWidth / source.width;
  final percent = (ratio * 100).round();
  return '$percent%';
}

/// 留白底色候选（PRD 三.2「支持透明底色、自定义纯色」）。
///
/// UI 直接遍历；值为 null 表示透明，取 [ResizeTarget.transparentBackground]。
const Map<String, int?> resizeBackgrounds = {
  '透明': null,
  '白色': 0xFFFFFFFF,
  '黑色': 0xFF000000,
  '浅灰': 0xFFF2F2F2,
};
