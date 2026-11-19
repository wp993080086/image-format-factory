import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'cjk_text.dart';

/// 标注类型（PRD v0.5 / M3，用户指定七类 + v0.6 涂抹打码）。
enum AnnotationType {
  text,
  line,
  arrow,
  rectangle,
  circle,
  ellipse,
  mosaic,

  /// 画笔涂抹打码：沿一条自由轨迹打码（马赛克 / 高斯模糊二选一）。
  ///
  /// 与 [mosaic] 的区别：mosaic 是矩形框，一次覆盖；brush 是一串连续点，
  /// 适合"随手抹几笔"把昵称、头像涂抹掉（v0.6 用户新增需求）。
  brush,
}

/// 涂抹打码的填充方式。
enum BrushMode {
  /// 分块取平均色的马赛克。
  mosaic,

  /// 高斯模糊（毛玻璃）。
  blur,
}

/// 一条标注（矢量数据，不直接改像素，支持撤销/重做与二次编辑）。
///
/// 坐标用原图像素系；[x2]/[y2] 对文字/马赛克表示框的右下角，对线/箭头表示终点。
/// [brush] 类型不使用 x1/y1/x2/y2，轨迹存在 [points] 里。
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
    this.points = const <int>[],
    this.brushMode = BrushMode.mosaic,
    this.brushRadius = 24,
  });

  final AnnotationType type;
  final int x1;
  final int y1;
  final int x2;
  final int y2;

  /// 颜色 ARGB（马赛克/涂抹忽略）。
  final int colorArgb;

  /// 线宽（矩形/圆/椭圆/线/箭头）。
  final int strokeWidth;

  /// 文字内容（仅 text 类型）。
  final String text;
  final int fontSize;

  /// 马赛克块边长（仅 mosaic 类型）。
  final int mosaicBlock;

  /// 涂抹轨迹，扁平的 [x0,y0,x1,y1,…] 原图坐标（仅 brush 类型）。
  ///
  /// 用扁平 int 列表而非 [Offset]：标注是跨 Isolate 传递的值对象，
  /// 纯 int 列表可零成本随其它字段一起送进编码 Isolate，不引入 Flutter 依赖。
  final List<int> points;

  /// 涂抹填充方式（仅 brush 类型）。
  final BrushMode brushMode;

  /// 笔刷半径，原图像素（仅 brush 类型）。
  final int brushRadius;

  /// 返回一份只改动指定字段的新标注（拖动/手柄调整时逐帧构造用）。
  Annotation copyWith({
    AnnotationType? type,
    int? x1,
    int? y1,
    int? x2,
    int? y2,
    int? colorArgb,
    int? strokeWidth,
    String? text,
    int? fontSize,
    int? mosaicBlock,
    List<int>? points,
    BrushMode? brushMode,
    int? brushRadius,
  }) =>
      Annotation(
        type: type ?? this.type,
        x1: x1 ?? this.x1,
        y1: y1 ?? this.y1,
        x2: x2 ?? this.x2,
        y2: y2 ?? this.y2,
        colorArgb: colorArgb ?? this.colorArgb,
        strokeWidth: strokeWidth ?? this.strokeWidth,
        text: text ?? this.text,
        fontSize: fontSize ?? this.fontSize,
        mosaicBlock: mosaicBlock ?? this.mosaicBlock,
        points: points ?? this.points,
        brushMode: brushMode ?? this.brushMode,
        brushRadius: brushRadius ?? this.brushRadius,
      );
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
      // 内嵌中文字体（按字号缩放），支持中文文字标注
      final font = CjkText.fontFor(a.text, a.fontSize);
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
    case AnnotationType.brush:
      _applyBrush(image, a);
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

/// 涂抹打码：沿一条自由轨迹把覆盖区域打码。
///
/// 两步：先把轨迹（点间线性插值，避免快速拖动留缝）连同笔刷半径烘成一张
/// 覆盖掩码，再按 [BrushMode] 只对掩码内的像素填充——马赛克取块内平均色，
/// 模糊则整图高斯模糊后把掩码内的像素换回。
void _applyBrush(img.Image image, Annotation a) {
  final pts = a.points;
  if (pts.length < 2) return;
  final radius = math.max(1, a.brushRadius);
  final w = image.width;
  final h = image.height;
  final mask = Uint8List(w * h);

  // 1) 烘轨迹掩码：相邻点插值，每个采样点用圆刷覆盖。
  //    步长取半径的一半，保证刷子连续无断点。
  final step = math.max(1.0, radius / 2.0);
  void stampCircle(int cx, int cy) {
    final r2 = radius * radius;
    final x0 = math.max(0, cx - radius);
    final x1 = math.min(w - 1, cx + radius);
    final y0 = math.max(0, cy - radius);
    final y1 = math.min(h - 1, cy + radius);
    for (var y = y0; y <= y1; y++) {
      for (var x = x0; x <= x1; x++) {
        final dx = x - cx;
        final dy = y - cy;
        if (dx * dx + dy * dy <= r2) mask[y * w + x] = 1;
      }
    }
  }

  for (var i = 0; i + 3 < pts.length; i += 2) {
    final x0 = pts[i];
    final y0 = pts[i + 1];
    final x1 = pts[i + 2];
    final y1 = pts[i + 3];
    final dx = x1 - x0;
    final dy = y1 - y0;
    final dist = math.sqrt(dx * dx + dy * dy);
    final n = math.max(1, (dist / step).round());
    for (var k = 0; k <= n; k++) {
      final t = k / n;
      stampCircle((x0 + dx * t).round(), (y0 + dy * t).round());
    }
  }
  if (pts.length == 2) stampCircle(pts[0], pts[1]);

  // 2) 按模式填充掩码区域。
  switch (a.brushMode) {
    case BrushMode.mosaic:
      _mosaicMasked(image, mask, math.max(2, a.mosaicBlock));
    case BrushMode.blur:
      _blurMasked(image, mask, radius);
  }
}

/// 掩码内按块取平均色打马赛克：块的统计与填充都只作用于掩码内像素，
/// 避免把涂抹边界外的干净区域也糊掉。
void _mosaicMasked(img.Image image, Uint8List mask, int block) {
  final w = image.width;
  final h = image.height;
  for (var by = 0; by < h; by += block) {
    for (var bx = 0; bx < w; bx += block) {
      final ex = math.min(bx + block - 1, w - 1);
      final ey = math.min(by + block - 1, h - 1);
      num r = 0, g = 0, b = 0;
      var count = 0;
      for (var y = by; y <= ey; y++) {
        for (var x = bx; x <= ex; x++) {
          if (mask[y * w + x] == 0) continue;
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
      for (var y = by; y <= ey; y++) {
        for (var x = bx; x <= ex; x++) {
          if (mask[y * w + x] == 1) image.setPixel(x, y, color);
        }
      }
    }
  }
}

/// 掩码内做高斯模糊：整图模糊一次，再把掩码内的像素换回原图。
/// 半径取笔刷半径（涂抹通常要足够糊才能盖住文字），并随半径增大而增强。
void _blurMasked(img.Image image, Uint8List mask, int brushRadius) {
  final radius = (brushRadius * 1.5).round().clamp(1, 40);
  final blurred = img.gaussianBlur(image, radius: radius);
  final w = image.width;
  final h = image.height;
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      if (mask[y * w + x] == 1) image.setPixel(x, y, blurred.getPixel(x, y));
    }
  }
}

/// 把「原图坐标系」的标注映射到「裁剪 + 缩放后」的输出坐标系。
///
/// 编码管线是「裁剪 → 缩放 → 合成标注」，而画布上的标注存原图坐标，
/// 导出前必须做这一步，否则裁剪/缩放后标注会错位。
/// 线宽、字号、马赛克块不随缩放改变（PRD 一.7：尺寸变换不应拉伸标注）。
///
/// [cropX]/[cropY]/[cropW]/[cropH] 为裁剪区（无裁剪传 0,0,原图宽,原图高）；
/// [outW]/[outH] 为输出尺寸（无缩放传裁剪区宽高）。
List<Annotation> transformAnnotations(
  List<Annotation> source, {
  required int cropX,
  required int cropY,
  required int cropW,
  required int cropH,
  required int outW,
  required int outH,
}) {
  if (source.isEmpty) return source;
  if (cropW <= 0 || cropH <= 0 || outW <= 0 || outH <= 0) return source;
  final sx = outW / cropW;
  final sy = outH / cropH;
  if (cropX == 0 && cropY == 0 && sx == 1 && sy == 1) return source;

  int mapX(int x) => ((x - cropX) * sx).round();
  int mapY(int y) => ((y - cropY) * sy).round();

  return [
    for (final a in source)
      a.copyWith(
        x1: mapX(a.x1),
        y1: mapY(a.y1),
        x2: mapX(a.x2),
        y2: mapY(a.y2),
        points: a.points.isEmpty
            ? a.points
            : [
                for (var i = 0; i < a.points.length; i += 2) ...[
                  mapX(a.points[i]),
                  mapY(a.points[i + 1]),
                ],
              ],
      ),
  ];
}
