import 'dart:math' as math;

import 'package:image/image.dart' as img;

import 'crop_selection.dart';

/// 在已校正方向的全图上应用裁剪（PRD 二.6 / 二.7）。
///
/// - 矩形：直接像素拷贝，**不涉及重采样**（PRD 二章注）；
/// - 圆形：先裁成方形画布，再按圆形遮罩把圆外置透明，边缘保留 1px 抗锯齿
///   过渡带（PRD 二.7）。
///
/// 返回图统一为 4 通道，保证后续透明填底与 PNG 导出行为一致。
img.Image applyCrop(img.Image source, CropArea area, {bool circle = false}) {
  final rect = _clampArea(area, source.width, source.height);
  final cropped = img.copyCrop(
    source,
    x: rect.x,
    y: rect.y,
    width: rect.width,
    height: rect.height,
  );
  final rgba = cropped.numChannels == 4 && !cropped.hasPalette
      ? cropped
      : cropped.convert(numChannels: 4);
  if (circle) _maskCircle(rgba);
  return rgba;
}

/// 把裁剪区收进图片边界；非法时退化为整图，避免产生空图。
CropArea _clampArea(CropArea area, int width, int height) {
  final x = area.x.clamp(0, math.max(0, width - 1)).toInt();
  final y = area.y.clamp(0, math.max(0, height - 1)).toInt();
  final w = area.width.clamp(1, width - x).toInt();
  final h = area.height.clamp(1, height - y).toInt();
  return CropArea(x: x, y: y, width: w, height: h);
}

/// 圆形遮罩：圆外 alpha 归零，边界按覆盖面积线性过渡。
///
/// 画布按外接正方形处理，边长取宽高较小值；像素中心到圆心的距离落在
/// `radius ± 0.5` 之间时视为部分覆盖，用 `radius - dist + 0.5` 近似覆盖率。
/// 用平方距离先做粗筛，只有边界带才开方，避免大图逐像素 `sqrt` 拖慢导出。
void _maskCircle(img.Image image) {
  final w = image.width;
  final h = image.height;
  final cx = w / 2;
  final cy = h / 2;
  final radius = math.min(w, h) / 2;
  final inner2 = math.max(0.0, radius - 0.5) * math.max(0.0, radius - 0.5);
  final outer2 = (radius + 0.5) * (radius + 0.5);

  for (var y = 0; y < h; y++) {
    final dy = y + 0.5 - cy;
    final dy2 = dy * dy;
    for (var x = 0; x < w; x++) {
      final dx = x + 0.5 - cx;
      final d2 = dx * dx + dy2;
      if (d2 <= inner2) continue; // 完全在圆内
      if (d2 >= outer2) {
        // 完全在圆外：只改 alpha，不动颜色，便于与其他透明区域统一处理
        final p = image.getPixel(x, y);
        if (p.a != 0) image.setPixelRgba(x, y, p.r, p.g, p.b, 0);
        continue;
      }
      final coverage = (radius - math.sqrt(d2) + 0.5).clamp(0.0, 1.0);
      final p = image.getPixel(x, y);
      image.setPixelRgba(x, y, p.r, p.g, p.b, (p.a * coverage).round());
    }
  }
}
