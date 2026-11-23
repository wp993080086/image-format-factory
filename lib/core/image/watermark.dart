import 'dart:math' as math;

import 'package:image/image.dart' as img;

import 'cjk_text.dart';

/// 文字水印锚点位置（PRD 需求池一.1：四角 + 居中）。
enum WatermarkPosition { topLeft, topRight, bottomLeft, bottomRight, center }

/// 文字水印参数（v0.5 / M3）。
///
/// 字体：内嵌 Noto Sans SC 点阵（见 [CjkText]），支持中文与 ASCII，
/// 字号按 24px 基准缩放，纯 Dart、后台 Isolate 可用。
class TextWatermark {
  const TextWatermark({
    required this.text,
    this.fontSize = 24,
    this.colorArgb = 0xFFFFFFFF,
    this.opacity = 100,
    this.rotation = 0,
    this.position = WatermarkPosition.bottomRight,
    this.margin = 16,
    this.repeat = false,
  });

  /// 水印文字（支持中文与 ASCII，常用汉字取 GB2312 一级字库）。
  final String text;

  /// 字号（像素），按 24px 基准缩放字形。
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

  /// 全屏重复（平铺）铺满；开启时忽略 [position]。
  final bool repeat;

  bool get isEmpty => text.trim().isEmpty || opacity <= 0;

  TextWatermark copyWithText(String text) => copyWith(text: text);

  TextWatermark copyWith({
    String? text,
    int? fontSize,
    int? colorArgb,
    int? opacity,
    int? rotation,
    WatermarkPosition? position,
    int? margin,
    bool? repeat,
  }) => TextWatermark(
    text: text ?? this.text,
    fontSize: fontSize ?? this.fontSize,
    colorArgb: colorArgb ?? this.colorArgb,
    opacity: opacity ?? this.opacity,
    rotation: rotation ?? this.rotation,
    position: position ?? this.position,
    margin: margin ?? this.margin,
    repeat: repeat ?? this.repeat,
  );
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
  // 用内嵌中文字体（按字号缩放），支持中文与 ASCII
  final font = CjkText.fontFor(w.text, w.fontSize);

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
  // 画布留 4px 余量，避免字形 xOffset/yOffset 为负时被裁切
  final layer = img.Image(width: textW + 4, height: textH + 4, numChannels: 4);
  img.drawString(layer, w.text, font: font, x: 2, y: 2, color: color);

  img.Image placed = layer;
  if (w.rotation != 0) {
    placed = img.copyRotate(
      layer,
      angle: w.rotation.toDouble(),
      interpolation: img.Interpolation.linear,
    );
  }

  if (w.repeat) {
    // 全屏平铺：网格间距在文字尺寸基础上留白，至少 1px 避免死循环。
    final gapX = math.max(1, (placed.width * 0.6).round());
    final gapY = math.max(1, (placed.height * 0.6).round());
    for (var y = w.margin; y < result.height; y += placed.height + gapY) {
      for (var x = w.margin; x < result.width; x += placed.width + gapX) {
        img.compositeImage(result, placed, dstX: x, dstY: y);
      }
    }
  } else {
    final pos = _anchor(
      w.position,
      source.width,
      source.height,
      placed.width,
      placed.height,
      w.margin,
    );
    img.compositeImage(result, placed, dstX: pos.x, dstY: pos.y);
  }
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
    WatermarkPosition.bottomRight => (
      x: math.max(0, maxX - m),
      y: math.max(0, maxY - m),
    ),
    WatermarkPosition.center => (x: (maxX / 2).round(), y: (maxY / 2).round()),
  };
}

int _a(int argb) => (argb >> 24) & 0xFF;
int _r(int argb) => (argb >> 16) & 0xFF;
int _g(int argb) => (argb >> 8) & 0xFF;
int _b(int argb) => argb & 0xFF;
