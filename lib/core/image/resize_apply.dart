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
  return switch (target.mode) {
    ResizeMode.stretch => _stretch(prepared, target),
    ResizeMode.cover => _cover(prepared, target),
    ResizeMode.contain => _contain(prepared, target),
  };
}

/// 拉伸填充：直接缩放到目标尺寸，不保持比例（PRD 三.2）。
img.Image _stretch(img.Image source, ResizeTarget target) {
  if (source.width == target.width && source.height == target.height) {
    return source;
  }
  return _resizeTo(source, target.width, target.height);
}

/// 裁剪填充：先按目标比例居中裁出源图，再缩放到目标尺寸（PRD 三.2）。
img.Image _cover(img.Image source, ResizeTarget target) {
  final rect = coverSourceRect(
    ImageDimensions(source.width, source.height),
    target.width,
    target.height,
  );
  var work = source;
  if (rect.width != source.width || rect.height != source.height) {
    work = img.copyCrop(
      source,
      x: rect.x,
      y: rect.y,
      width: rect.width,
      height: rect.height,
    );
  }
  if (work.width == target.width && work.height == target.height) return work;
  return _resizeTo(work, target.width, target.height);
}

/// 留白填充：等比缩进目标框，空白处填透明或纯色（PRD 三.2）。
img.Image _contain(img.Image source, ResizeTarget target) {
  final layout = containLayout(
    ImageDimensions(source.width, source.height),
    target.width,
    target.height,
  );
  final resized = layout.width == source.width && layout.height == source.height
      ? source
      : _resizeTo(source, layout.width, layout.height);

  // 内容刚好铺满目标框（比例完全一致）时没有留白，省掉一次画布合成
  if (layout.width == target.width && layout.height == target.height) {
    return resized;
  }

  final canvas = target.isTransparent
      ? img.Image(width: target.width, height: target.height, numChannels: 4)
      : _filledCanvas(target.width, target.height, target.backgroundArgb);
  img.compositeImage(
    canvas,
    resized,
    dstX: layout.dx,
    dstY: layout.dy,
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
