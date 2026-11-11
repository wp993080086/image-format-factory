import 'dart:math' as math;

import 'image_header_probe.dart';

/// 选区形状（PRD 二.2）。
enum CropShape {
  rectangle('矩形'),
  circle('圆形');

  const CropShape(this.label);

  final String label;
}

/// 比例预设（PRD 二.2 形状 × 比例合法性矩阵）。
enum CropAspect {
  free('自由', null),
  square('1:1', 1),
  ratio4x3('4:3', 4 / 3),
  ratio3x2('3:2', 3 / 2),
  ratio16x9('16:9', 16 / 9);

  const CropAspect(this.label, this.ratio);

  final String label;

  /// 宽高比；自由比例为 null。
  final double? ratio;

  /// 该比例对 [shape] 是否合法。
  ///
  /// 圆形选区本质是正方形选区加圆形遮罩，非 1:1 的比例一律非法（PRD 二.2）。
  bool allowedFor(CropShape shape) =>
      shape == CropShape.rectangle || ratio == null || ratio == 1;
}

/// 缩放手柄方位，`dx` / `dy` 取 -1、0、1 表示左中右、上中下。
enum CropHandle {
  topLeft(-1, -1),
  top(0, -1),
  topRight(1, -1),
  left(-1, 0),
  right(1, 0),
  bottomLeft(-1, 1),
  bottom(0, 1),
  bottomRight(1, 1);

  const CropHandle(this.dx, this.dy);

  final int dx;
  final int dy;

  bool get affectsLeft => dx < 0;
  bool get affectsRight => dx > 0;
  bool get affectsTop => dy < 0;
  bool get affectsBottom => dy > 0;
}

/// 整数裁剪区（原图像素坐标），供编码阶段直接拷贝像素。
///
/// 与 [CropSelection] 分离：前者是落地的最终结果，后者是编辑期的连续坐标。
class CropArea {
  const CropArea({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });

  final int x;
  final int y;
  final int width;
  final int height;

  bool get isEmpty => width <= 0 || height <= 0;

  /// 与 [other] 是否等价（用于判断「全图选区 = 不裁剪」）。
  bool sameAs(CropArea other) =>
      x == other.x &&
      y == other.y &&
      width == other.width &&
      height == other.height;

  @override
  String toString() => 'CropArea($x, $y, ${width}x$height)';
}

/// 裁剪选区，坐标定义在**原图坐标系**（PRD 二.5）。
///
/// 编辑期允许小数，落地前由 [toArea] 吸附到整数像素（PRD 二.4）。
class CropSelection {
  const CropSelection({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  });

  /// 全图选区（PRD：导入后默认全选整图）。
  factory CropSelection.full(ImageDimensions size) => CropSelection(
    left: 0,
    top: 0,
    width: size.width.toDouble(),
    height: size.height.toDouble(),
  );

  final double left;
  final double top;
  final double width;
  final double height;

  double get right => left + width;
  double get bottom => top + height;
  double get centerX => left + width / 2;
  double get centerY => top + height / 2;

  /// 宽高比。
  double get aspectRatio => height == 0 ? 1 : width / height;

  /// 是否为覆盖整图的选区。
  bool covers(ImageDimensions size) {
    final area = toArea();
    return area.x == 0 &&
        area.y == 0 &&
        area.width == size.width &&
        area.height == size.height;
  }

  /// 吸附到整数像素并收敛为 [CropArea]（PRD 二.4：杜绝 1px 误差）。
  ///
  /// 用「两边分别取整、宽高由差值决定」而非「原点取整 + 宽高取整」，
  /// 保证右边界与下边界不因两次独立取整而漂移。
  CropArea toArea() {
    final x = left.round();
    final y = top.round();
    return CropArea(
      x: x,
      y: y,
      width: math.max(1, right.round() - x),
      height: math.max(1, bottom.round() - y),
    );
  }

  /// 平移选区（PRD 二.3：拖拽超出边界时吸附到图片边界）。
  CropSelection moved(double dx, double dy, ImageDimensions size) {
    final maxLeft = math.max(0.0, size.width - width);
    final maxTop = math.max(0.0, size.height - height);
    return CropSelection(
      left: (left + dx).clamp(0.0, maxLeft),
      top: (top + dy).clamp(0.0, maxTop),
      width: width,
      height: height,
    );
  }

  /// 按比例重新生成选区：保留中心与面积，宽高按比例重算后收进图内。
  CropSelection withAspect(
    CropAspect aspect,
    CropShape shape,
    ImageDimensions size,
  ) {
    // 圆形强制 1:1（PRD 二.2）
    final ratio = shape == CropShape.circle ? 1.0 : aspect.ratio;
    if (ratio == null) return this;

    final area = width * height;
    final w = math.max(1.0, math.sqrt(area * ratio));
    final h = math.max(1.0, w / ratio);
    return _centered(w, h, size);
  }

  /// 按目标像素尺寸重建选区（PRD 二.3）。
  ///
  /// 输入值为**原图像素**，超过原图对应边时钳制；以当前选区中心为锚点，
  /// 越界时整体向内平移至贴合边界。圆形选区时取外接正方形边长。
  CropSelection withTargetSize(
    int targetWidth,
    int targetHeight,
    ImageDimensions size,
    CropShape shape,
  ) {
    var w = targetWidth.clamp(1, size.width).toDouble();
    var h = targetHeight.clamp(1, size.height).toDouble();
    if (shape == CropShape.circle) {
      // 外接正方形：取两者较小值，避免圆形被拉成椭圆
      final side = math.min(w, h);
      w = side;
      h = side;
    }
    return _centered(w, h, size);
  }

  /// 拖动手柄调整大小。
  ///
  /// [dx] / [dy] 为原图坐标系的位移；比例锁定时按主导方向推导另一条边，
  /// 并以未拖动的边为锚点向外铺开。
  CropSelection resized(
    CropHandle handle,
    double dx,
    double dy,
    ImageDimensions size,
    CropAspect aspect,
    CropShape shape,
  ) {
    final ratio = shape == CropShape.circle ? 1.0 : aspect.ratio;

    // 未拖动的边保持不动，作为铺开锚点
    final fixedX = handle.affectsLeft ? right : left;
    final fixedY = handle.affectsTop ? bottom : top;

    var w = width;
    var h = height;
    if (handle.affectsLeft) w = right - (left + dx);
    if (handle.affectsRight) w = (right + dx) - left;
    if (handle.affectsTop) h = bottom - (top + dy);
    if (handle.affectsBottom) h = (bottom + dy) - top;

    w = math.max(1.0, w);
    h = math.max(1.0, h);

    if (ratio != null) {
      // 宽向手柄主导宽度，高向手柄主导高度
      if (handle.affectsLeft || handle.affectsRight) {
        h = w / ratio;
      } else {
        w = h * ratio;
      }
    }

    // 锚点向外可用空间不足时等比缩回，保证不越界
    final availableW = handle.affectsLeft ? fixedX : size.width - fixedX;
    final availableH = handle.affectsTop ? fixedY : size.height - fixedY;
    final scale = math.min(1.0, math.min(availableW / w, availableH / h));
    w *= scale;
    h *= scale;

    final l = handle.affectsLeft ? fixedX - w : fixedX;
    final t = handle.affectsTop ? fixedY - h : fixedY;
    return CropSelection(
      left: l,
      top: t,
      width: math.max(1.0, w),
      height: math.max(1.0, h),
    );
  }

  /// 以当前中心为锚点生成指定宽高的选区，越界则整体平移至贴合（PRD 二.3）。
  ///
  /// 宽高先按图片尺寸等比收进边界：切换比例时面积可能超出整图，
  /// 只平移不缩放会得到一张超出画布的选区。
  CropSelection _centered(double w, double h, ImageDimensions size) {
    final scale = math.min(1.0, math.min(size.width / w, size.height / h));
    final cw = w * scale;
    final ch = h * scale;
    final l = (centerX - cw / 2)
        .clamp(0.0, math.max(0.0, size.width - cw))
        .toDouble();
    final t = (centerY - ch / 2)
        .clamp(0.0, math.max(0.0, size.height - ch))
        .toDouble();
    return CropSelection(left: l, top: t, width: cw, height: ch);
  }

  @override
  String toString() =>
      'CropSelection(${left.toStringAsFixed(1)}, ${top.toStringAsFixed(1)}, '
      '${width.toStringAsFixed(1)}x${height.toStringAsFixed(1)})';
}
