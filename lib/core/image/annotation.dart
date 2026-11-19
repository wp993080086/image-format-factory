import 'dart:math' as math;

import 'package:image/image.dart' as img;

/// 标注类型（PRD v0.5 / M3，用户指定七类）。
enum AnnotationType {
  text,
  line,
  arrow,
  rectangle,
  circle,
  ellipse,
  mosaic,
}

/// 一条标注（矢量数据，不直接改像素，支持撤销/重做与二次编辑）。
///
/// 坐标用原图像素系；[x2]/[y2] 对文字/马赛克表示框的右下角，对线/箭头表示终点。
class Annotation {
  const Annotation({
    required this.type,
    required this.x1,
    required this.y1,
    required this.x2,
    required this.y2,
    this.colorArgb = 0xFFFF0000,
    this.strokeWidth = 3,
    this.text = '',
    this.fontSize = 24,
    this.mosaicBlock = 12,
  });

  final AnnotationType type;
  final int x1;
  final int y1;
  final int x2;
  final int y2;

  /// 颜色 ARGB（马赛克忽略）。
  final int colorArgb;

  /// 线宽（矩形/圆/椭圆/线/箭头）。
  final int strokeWidth;

  /// 文字内容（仅 text 类型）。
  final String text;
  final int fontSize;

  /// 马赛克块边长（仅 mosaic 类型）。
  final int mosaicBlock;
}

/// 把一组标注按矢量数据合成到位图，返回新图。
///
/// 合成顺序由调用方保证在「裁剪 → 缩放」之后（PRD 一.7 实现要点）：
/// 本函数只管在当前位图上叠加，不再做任何几何变换，否则线宽会被拉伸。
img.Image applyAnnotations(img.Image source, List<Annotation> annotations) {
  if (annotations.isEmpty) return source;
  final result = img.Image.from(source);
  for (final a in annotations) {
    _drawOne(result, a);
  }
  return result;
}

void _drawOne(img.Image image, Annotation a) {
  final color = img.ColorRgba8(
    (a.colorArgb >> 16) & 0xFF,
    (a.colorArgb >> 8) & 0xFF,
    a.colorArgb & 0xFF,
    (a.colorArgb >> 24) & 0xFF,
  );
  switch (a.type) {
    case AnnotationType.text:
      final font = a.fontSize <= 14
          ? img.arial14
          : a.fontSize >= 48
              ? img.arial48
              : img.arial24;
      img.drawString(image, a.text, font: font, x: a.x1, y: a.y1, color: color);
    case AnnotationType.line:
      img.drawLine(
        image,
        x1: a.x1,
        y1: a.y1,
        x2: a.x2,
        y2: a.y2,
        color: color,
        thickness: a.strokeWidth.toDouble(),
        antialias: true,
      );
    case AnnotationType.arrow:
      _drawArrow(image, a, color);
    case AnnotationType.rectangle:
      img.drawRect(
        image,
        x1: a.x1,
        y1: a.y1,
        x2: a.x2,
        y2: a.y2,
        color: color,
        thickness: a.strokeWidth.toDouble(),
      );
    case AnnotationType.circle:
      // 用等半径的多边形画描边圆（drawCircle 只支持填充，无 thickness）
      _drawEllipse(
        image,
        Annotation(
          type: AnnotationType.circle,
          x1: a.x1,
          y1: a.y1,
          x2: a.x2,
          y2: a.y2,
          colorArgb: a.colorArgb,
          strokeWidth: a.strokeWidth,
        ),
        color,
      );
    case AnnotationType.ellipse:
      _drawEllipse(image, a, color);
    case AnnotationType.mosaic:
      _applyMosaic(image, a);
  }
}

void _drawArrow(img.Image image, Annotation a, img.Color color) {
  final dx = a.x2 - a.x1;
  final dy = a.y2 - a.y1;
  final len = math.sqrt(dx * dx + dy * dy);
  if (len < 1) return;
  img.drawLine(
    image,
    x1: a.x1,
    y1: a.y1,
    x2: a.x2,
    y2: a.y2,
    color: color,
    thickness: a.strokeWidth.toDouble(),
    antialias: true,
  );
  // 箭头三角：在终点沿反方向偏 ±30°
  final head = math.max(8.0, a.strokeWidth * 4.0);
  final ang = math.atan2(dy, dx);
  const wing = 0.5;
  final p1 = (
    x: (a.x2 - head * math.cos(ang - wing)).round(),
    y: (a.y2 - head * math.sin(ang - wing)).round(),
  );
  final p2 = (
    x: (a.x2 - head * math.cos(ang + wing)).round(),
    y: (a.y2 - head * math.sin(ang + wing)).round(),
  );
  img.drawPolygon(
    image,
    vertices: [
      img.Point(a.x2, a.y2),
      img.Point(p1.x, p1.y),
      img.Point(p2.x, p2.y),
    ],
    color: color,
    antialias: true,
  );
}

/// 椭圆用多边形采样近似（image 包无 drawEllipse）。
void _drawEllipse(img.Image image, Annotation a, img.Color color) {
  final cx = (a.x1 + a.x2) / 2;
  final cy = (a.y1 + a.y2) / 2;
  final rx = (a.x2 - a.x1).abs() / 2;
  final ry = (a.y2 - a.y1).abs() / 2;
  if (rx < 1 || ry < 1) return;
  const steps = 72;
  final points = <img.Point>[];
  for (var i = 0; i < steps; i++) {
    final t = 2 * math.pi * i / steps;
    points.add(
      img.Point(
        (cx + rx * math.cos(t)).round(),
        (cy + ry * math.sin(t)).round(),
      ),
    );
  }
  img.drawPolygon(
    image,
    vertices: points,
    color: color,
    thickness: a.strokeWidth.toDouble(),
    antialias: true,
  );
}

/// 马赛克：把框内像素按块取平均色后填回，实现打码。
void _applyMosaic(img.Image image, Annotation a) {
  final left = math.max(0, math.min(a.x1, a.x2));
  final top = math.max(0, math.min(a.y1, a.y2));
  final right = math.min(image.width - 1, math.max(a.x1, a.x2));
  final bottom = math.min(image.height - 1, math.max(a.y1, a.y2));
  final block = math.max(2, a.mosaicBlock);

  for (var by = top; by <= bottom; by += block) {
    for (var bx = left; bx <= right; bx += block) {
      final ex = math.min(bx + block - 1, right);
      final ey = math.min(by + block - 1, bottom);
      num r = 0, g = 0, b = 0;
      var count = 0;
      for (var y = by; y <= ey; y++) {
        for (var x = bx; x <= ex; x++) {
          final p = image.getPixel(x, y);
          r += p.r;
          g += p.g;
          b += p.b;
          count++;
        }
      }
      if (count == 0) continue;
      final color = img.ColorRgba8(
        (r / count).round(),
        (g / count).round(),
        (b / count).round(),
        255,
      );
      img.fillRect(image, x1: bx, y1: by, x2: ex, y2: ey, color: color);
    }
  }
}
