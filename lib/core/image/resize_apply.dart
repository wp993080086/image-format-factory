import 'package:image/image.dart' as img;

import 'image_header_probe.dart';
import 'resize_geometry.dart';

/// 在已裁剪的位图上应用目标尺寸与填充方式（PRD 三章）。
///
/// 重采样统一用 cubic：`image` 包无 lanczos 实现（PRD 三.3 v0.2 注），
/// cubic 是包内质量最高的插值。
img.Image applyResize(img.Image source, ResizeTarget target) {
  // 索引色图无法参与 cubic 重采样（copyResize 会强制降为 nearest），
  // 先展开为 RGBA；其余源保持原样，避免大图多占一份内存。
  final prepared = source.hasPalette ? source.convert(numChannels: 4) : source;
  final geometry = computeResizeGeometry(
    ImageDimensions(prepared.width, prepared.height),
    target,
  );
  return switch (target.mode) {
    ResizeMode.stretch => _stretch(prepared, geometry),
    ResizeMode.cover => _cover(prepared, geometry),
    ResizeMode.contain => _contain(prepared, geometry, target),
  };
}

/// 拉伸填充：直接缩放到目标尺寸，不保持比例（PRD 三.2）。
img.Image _stretch(img.Image source, ResizeGeometry geometry) {
  if (geometry.contentWidth == source.width &&
      geometry.contentHeight == source.height) {
    return source;
  }
  return _resizeTo(source, geometry.contentWidth, geometry.contentHeight);
}

/// 裁剪填充：先按目标比例居中裁出源图，再缩放到目标尺寸（PRD 三.2）。
img.Image _cover(img.Image source, ResizeGeometry geometry) {
  var work = source;
  if (geometry.srcX != 0 ||
      geometry.srcY != 0 ||
      geometry.srcWidth != source.width ||
      geometry.srcHeight != source.height) {
    work = img.copyCrop(
      source,
      x: geometry.srcX,
      y: geometry.srcY,
      width: geometry.srcWidth,
      height: geometry.srcHeight,
    );
  }
  if (work.width == geometry.contentWidth &&
      work.height == geometry.contentHeight) {
    return work;
  }
  return _resizeTo(work, geometry.contentWidth, geometry.contentHeight);
}

/// 留白填充：等比缩进目标框，空白处填透明或纯色（PRD 三.2）。
img.Image _contain(
  img.Image source,
  ResizeGeometry geometry,
  ResizeTarget target,
) {
  final resized =
      geometry.contentWidth == source.width &&
          geometry.contentHeight == source.height
      ? source
      : _resizeTo(source, geometry.contentWidth, geometry.contentHeight);

  // 内容刚好铺满目标框（比例完全一致）时没有留白，省掉一次画布合成
  if (geometry.contentWidth == geometry.width &&
      geometry.contentHeight == geometry.height) {
    return resized;
  }

  final canvas = target.isTransparent
      ? img.Image(
          width: geometry.width,
          height: geometry.height,
          numChannels: 4,
        )
      : _filledCanvas(geometry.width, geometry.height, target.backgroundArgb);
  img.compositeImage(
    canvas,
    resized,
    dstX: geometry.dx,
    dstY: geometry.dy,
    // 透明底用 direct 直写：alpha 混合会让抗锯齿边缘被二次淡化。
    // 实色底必须用 alpha 混合，否则源图自身的透明像素会盖住底色。
    blend: target.isTransparent ? img.BlendMode.direct : img.BlendMode.alpha,
  );
  return canvas;
}

img.Image _resizeTo(img.Image source, int width, int height) => img.copyResize(
  source,
  width: width,
  height: height,
  interpolation: img.Interpolation.cubic,
);

/// 不透明底色画布：只取 RGB 三个通道，alpha 恒为 255。
img.Image _filledCanvas(int width, int height, int argb) {
  final canvas = img.Image(width: width, height: height, numChannels: 3);
  img.fill(
    canvas,
    color: img.ColorRgb8((argb >> 16) & 0xFF, (argb >> 8) & 0xFF, argb & 0xFF),
  );
  return canvas;
}
