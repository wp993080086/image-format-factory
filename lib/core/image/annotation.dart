import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'cjk_text.dart';
import 'image_header_probe.dart';
import 'resize_geometry.dart';

/// 标注类型（PRD v0.5 / M3，用户指定七类 + v0.6 涂抹打码）。
enum AnnotationType {
  text,
  line,
  arrow,
  rectangle,
  circle,
  ellipse,
  mosaic,

  /// 画笔涂抹打码：沿一条自由轨迹打块中心取色的马赛克。
  ///
  /// 与 [mosaic] 的区别：mosaic 是矩形框，一次覆盖；brush 是一串连续点，
  /// 适合"随手抹几笔"把昵称、头像涂抹掉（v0.6 用户新增需求）。
  brush,
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

  /// 笔刷半径，原图像素（仅 brush 类型）。
  final int brushRadius;

  /// 把所有坐标钳制到图片范围内，避免标注伸出图片外。
  ///
  /// 框类标注整体平移（保持宽高），涂抹轨迹逐点钳制；宽高超过图片时不拉伸，
  /// 只把左上角归零，导出端仍会按图片边界裁掉超出部分。
  Annotation clampToBounds(int width, int height) {
    if (width <= 0 || height <= 0) return this;
    if (type == AnnotationType.brush) {
      final pts = <int>[
        for (var i = 0; i < points.length; i += 2) ...[
          points[i].clamp(0, width - 1).toInt(),
          points[i + 1].clamp(0, height - 1).toInt(),
        ],
      ];
      if (pts.length < 2) return this;
      var minX = pts[0], maxX = pts[0];
      var minY = pts[1], maxY = pts[1];
      for (var i = 2; i < pts.length; i += 2) {
        minX = math.min(minX, pts[i]);
        maxX = math.max(maxX, pts[i]);
        minY = math.min(minY, pts[i + 1]);
        maxY = math.max(maxY, pts[i + 1]);
      }
      return copyWith(points: pts, x1: minX, y1: minY, x2: maxX, y2: maxY);
    }
    final left = math.min(x1, x2);
    final top = math.min(y1, y2);
    final boxW = (x1 - x2).abs();
    final boxH = (y1 - y2).abs();
    final newLeft = left.clamp(0, math.max(0, width - boxW));
    final newTop = top.clamp(0, math.max(0, height - boxH));
    final dx = (newLeft - left).toInt();
    final dy = (newTop - top).toInt();
    if (dx == 0 && dy == 0) return this;
    return copyWith(x1: x1 + dx, y1: y1 + dy, x2: x2 + dx, y2: y2 + dy);
  }

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
    int? brushRadius,
  }) => Annotation(
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
    _drawOne(result, a.clampToBounds(source.width, source.height));
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
      // 内嵌中文字体（按字号缩放），支持中文文字标注；
      // 框以落点为中心生成，字形按点阵度量在框内垂直居中。
      final font = CjkText.fontFor(a.text, a.fontSize);
      img.drawString(
        image,
        a.text,
        font: font,
        x: a.x1,
        y: a.y1 + CjkText.centeredYOffset(a.text, a.fontSize),
        color: color,
      );
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

/// 取一个块的中心像素色：整块填同一个色，相邻块取不同底图像素，
/// 形成经典像素格子马赛克。每块只采样一次，拖动预览逐帧重绘时不会卡顿。
/// 块矩形由调用方给定（已钳到边界）。
img.Color _blockCenterColor(img.Image image, int bx, int by, int ex, int ey) {
  final x = ((bx + ex) ~/ 2).clamp(0, image.width - 1);
  final y = ((by + ey) ~/ 2).clamp(0, image.height - 1);
  final p = image.getPixel(x, y);
  return img.ColorRgba8(
    p.r.toInt(),
    p.g.toInt(),
    p.b.toInt(),
    image.hasAlpha ? p.a.toInt() : 255,
  );
}

/// 矩形马赛克：按块中心底图像素填色，整块统一。
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
      img.fillRect(
        image,
        x1: bx,
        y1: by,
        x2: ex,
        y2: ey,
        color: _blockCenterColor(image, bx, by, ex, ey),
      );
    }
  }
}

/// 涂抹打码：沿一条自由轨迹把覆盖区域打成马赛克。
///
/// 两步：先把轨迹（点间线性插值，避免快速拖动留缝）连同笔刷半径烘成一张
/// 覆盖掩码，再对掩码内的像素按块中心取色填色。
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

  // 2) 掩码内按块中心取色填色。
  _mosaicMasked(image, mask, math.max(2, a.mosaicBlock));
}

/// 掩码内按块中心取色填充：块坐标取全局网格，预览与导出一致。
/// 只作用于掩码内像素，不碰边界外的干净区域。
void _mosaicMasked(img.Image image, Uint8List mask, int block) {
  final w = image.width;
  final h = image.height;
  for (var by = 0; by < h; by += block) {
    for (var bx = 0; bx < w; bx += block) {
      final ex = math.min(bx + block - 1, w - 1);
      final ey = math.min(by + block - 1, h - 1);
      final color = _blockCenterColor(image, bx, by, ex, ey);
      for (var y = by; y <= ey; y++) {
        for (var x = bx; x <= ex; x++) {
          if (mask[y * w + x] == 1) image.setPixel(x, y, color);
        }
      }
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
/// [resize] 为尺寸变换配置，与像素管线共用 [computeResizeGeometry]，
/// 因此 cover 的二次裁剪与 contain 的留白偏移对标注同样生效。
List<Annotation> transformAnnotations(
  List<Annotation> source, {
  required int cropX,
  required int cropY,
  required int cropW,
  required int cropH,
  ResizeTarget? resize,
}) {
  if (source.isEmpty) return source;
  if (cropW <= 0 || cropH <= 0) return source;
  final geometry = resize == null
      ? ResizeGeometry.identity(cropW, cropH)
      : computeResizeGeometry(ImageDimensions(cropW, cropH), resize);
  final unchanged =
      cropX == 0 &&
      cropY == 0 &&
      geometry.srcX == 0 &&
      geometry.srcY == 0 &&
      geometry.contentWidth == cropW &&
      geometry.contentHeight == cropH &&
      geometry.dx == 0 &&
      geometry.dy == 0;
  if (unchanged) return source;

  int mapX(int x) => geometry.mapX(x - cropX);
  int mapY(int y) => geometry.mapY(y - cropY);

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
