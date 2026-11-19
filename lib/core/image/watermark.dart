import 'dart:math' as math;

import 'package:image/image.dart' as img;

/// 文字水印锚点位置（PRD 需求池一.1：四角 + 居中）。
enum WatermarkPosition {
  topLeft,
  topRight,
  bottomLeft,
  bottomRight,
  center,
}

/// 文字水印参数（v0.5 / M3）。
///
/// 注意字体限制：`image` 包自带 arial 位图字体只含 ASCII，中文字符会被
/// `drawString` 跳过（不渲染）。要支持中文需打包点阵字体或改走平台文本渲染，
/// 属 M3 后续项；本实现保证 ASCII 水印完整可用，中文不崩溃但不显示。
class TextWatermark {
  const TextWatermark({
    required this.text,
    this.fontSize = 24,
    this.colorArgb = 0xFFFFFFFF,
    this.opacity = 100,
    this.rotation = 0,
    this.position = WatermarkPosition.bottomRight,
    this.margin = 16,
  });

  /// 水印文字（ASCII）。
  final String text;

  /// 字号：选 arial14/24/48 中最接近的一档。
  final int fontSize;

  /// 颜色（ARGB 32 位）。
  final int colorArgb;

  /// 不透明度 0–100。
  final int opacity;

  /// 旋转角度（度）。
  final int rotation;

  final WatermarkPosition position;

  /// 距边缘的像素边距。
  final int margin;

  bool get isEmpty => text.trim().isEmpty || opacity <= 0;

  TextWatermark copyWithText(String text) => TextWatermark(
        text: text,
        fontSize: fontSize,
        colorArgb: colorArgb,
        opacity: opacity,
        rotation: rotation,
        position: position,
        margin: margin,
      );

  img.BitmapFont get _font {
    if (fontSize <= 14) return img.arial14;
    if (fontSize >= 48) return img.arial48;
    return img.arial24;
  }
}

/// 把文字水印合成到位图，返回新图（不修改入参）。
img.Image applyTextWatermark(img.Image source, TextWatermark w) {
  if (w.isEmpty) return source;
  final result = img.Image.from(source);

  final alpha = (_a(w.colorArgb) * w.opacity / 100).round().clamp(0, 255);
  final color = img.ColorRgba8(
    _r(w.colorArgb),
    _g(w.colorArgb),
    _b(w.colorArgb),
    alpha,
  );
  final font = w._font;

  // 量出文字实际尺寸，用于定位与旋转画布
  var textW = 0;
  var textH = 0;
  for (var c in w.text.codeUnits) {
    final ch = font.characters[c];
    if (ch == null) continue;
    textW += ch.xAdvance;
    textH = math.max(textH, ch.height + ch.yOffset);
  }
  if (textW <= 0 || textH <= 0) return result;

  // 在独立透明画布上画文字，支持旋转后再整体合成
  final layer = img.Image(width: textW, height: textH, numChannels: 4);
  img.drawString(layer, w.text, font: font, x: 0, y: 0, color: color);

  img.Image placed = layer;
  if (w.rotation != 0) {
    placed = img.copyRotate(
      layer,
      angle: w.rotation.toDouble(),
      interpolation: img.Interpolation.linear,
    );
  }

  final pos = _anchor(
    w.position,
    source.width,
    source.height,
    placed.width,
    placed.height,
    w.margin,
  );
  img.compositeImage(result, placed, dstX: pos.x, dstY: pos.y);
  return result;
}

({int x, int y}) _anchor(
  WatermarkPosition p,
  int iw,
  int ih,
  int ww,
  int wh,
  int m,
) {
  final maxX = math.max(0, iw - ww);
  final maxY = math.max(0, ih - wh);
  return switch (p) {
    WatermarkPosition.topLeft => (x: m, y: m),
    WatermarkPosition.topRight => (x: math.max(0, maxX - m), y: m),
    WatermarkPosition.bottomLeft => (x: m, y: math.max(0, maxY - m)),
    WatermarkPosition.bottomRight => (x: math.max(0, maxX - m), y: math.max(0, maxY - m)),
    WatermarkPosition.center => (x: (maxX / 2).round(), y: (maxY / 2).round()),
  };
}

int _a(int argb) => (argb >> 24) & 0xFF;
int _r(int argb) => (argb >> 16) & 0xFF;
int _g(int argb) => (argb >> 8) & 0xFF;
int _b(int argb) => argb & 0xFF;
