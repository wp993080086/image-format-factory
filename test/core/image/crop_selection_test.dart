import 'package:flutter_test/flutter_test.dart';
import 'package:pixel_forge/core/image/crop_selection.dart';
import 'package:pixel_forge/core/image/image_header_probe.dart';

void main() {
  const size = ImageDimensions(1000, 800);

  group('形状 × 比例合法性（PRD 二.2 矩阵）', () {
    test('矩形支持全部比例', () {
      for (final aspect in CropAspect.values) {
        expect(aspect.allowedFor(CropShape.rectangle), isTrue);
      }
    });

    test('圆形仅支持自由与 1:1', () {
      expect(CropAspect.free.allowedFor(CropShape.circle), isTrue);
      expect(CropAspect.square.allowedFor(CropShape.circle), isTrue);
      for (final aspect in [
        CropAspect.ratio4x3,
        CropAspect.ratio3x2,
        CropAspect.ratio16x9,
      ]) {
        expect(aspect.allowedFor(CropShape.circle), isFalse);
      }
    });
  });

  group('选区基础', () {
    test('全图选区覆盖整图', () {
      final selection = CropSelection.full(size);
      expect(selection.left, 0);
      expect(selection.top, 0);
      expect(selection.width, 1000);
      expect(selection.height, 800);
      expect(selection.covers(size), isTrue);
    });

    test('toArea 吸附到整数像素', () {
      const selection = CropSelection(
        left: 10.4,
        top: 20.6,
        width: 99.6,
        height: 50.2,
      );
      final area = selection.toArea();
      expect(area.x, 10);
      expect(area.y, 21);
      // 右边界与下边界各自取整，宽度由差值决定，避免两次独立取整的漂移
      expect(area.width, 100); // round(110.0) - 10
      expect(area.height, 50); // round(70.8) - 21
    });

    test('选区退化时至少保留 1px', () {
      const selection = CropSelection(left: 5, top: 5, width: 0.2, height: 0.2);
      final area = selection.toArea();
      expect(area.width, greaterThanOrEqualTo(1));
      expect(area.height, greaterThanOrEqualTo(1));
    });

    test('非全图选区不算覆盖', () {
      const selection = CropSelection(left: 0, top: 0, width: 999, height: 800);
      expect(selection.covers(size), isFalse);
    });
  });

  group('平移（PRD 二.3 拖拽钳制）', () {
    test('向左上越界时吸附到 0', () {
      const selection = CropSelection(
        left: 10,
        top: 10,
        width: 100,
        height: 100,
      );
      final moved = selection.moved(-50, -50, size);
      expect(moved.left, 0);
      expect(moved.top, 0);
      expect(moved.width, 100);
      expect(moved.height, 100);
    });

    test('向右下越界时吸附到右/下边界', () {
      const selection = CropSelection(
        left: 800,
        top: 600,
        width: 100,
        height: 100,
      );
      final moved = selection.moved(500, 500, size);
      expect(moved.left, 900);
      expect(moved.top, 700);
      expect(moved.right, 1000);
      expect(moved.bottom, 800);
    });

    test('未越界时按位移量平移', () {
      const selection = CropSelection(
        left: 100,
        top: 100,
        width: 200,
        height: 200,
      );
      final moved = selection.moved(30, 40, size);
      expect(moved.left, 130);
      expect(moved.top, 140);
    });
  });

  group('比例切换（保留中心与面积）', () {
    test('切换 1:1 后宽高相等且中心不变', () {
      const selection = CropSelection(
        left: 400,
        top: 300,
        width: 200,
        height: 100,
      );
      final squared = selection.withAspect(
        CropAspect.square,
        CropShape.rectangle,
        size,
      );
      expect(squared.width, closeTo(squared.height, 0.001));
      expect(squared.centerX, closeTo(500, 0.001));
      expect(squared.centerY, closeTo(350, 0.001));
    });

    test('全图切 1:1 时等比收进图片，不溢出边界', () {
      final full = CropSelection.full(size);
      final squared = full.withAspect(
        CropAspect.square,
        CropShape.rectangle,
        size,
      );
      expect(squared.width, lessThanOrEqualTo(size.width));
      expect(squared.height, lessThanOrEqualTo(size.height));
      expect(squared.left, greaterThanOrEqualTo(0));
      expect(squared.top, greaterThanOrEqualTo(0));
    });

    test('圆形忽略传入比例，强制 1:1', () {
      const selection = CropSelection(
        left: 300,
        top: 300,
        width: 400,
        height: 200,
      );
      final circular = selection.withAspect(
        CropAspect.ratio16x9,
        CropShape.circle,
        size,
      );
      expect(circular.width, closeTo(circular.height, 0.001));
    });
  });

  group('目标像素尺寸（PRD 二.3）', () {
    test('以当前选区中心为锚点重建', () {
      const selection = CropSelection(
        left: 100,
        top: 100,
        width: 200,
        height: 200,
      );
      final result = selection.withTargetSize(
        400,
        400,
        size,
        CropShape.rectangle,
      );
      expect(result.width, 400);
      expect(result.height, 400);
      expect(result.centerX, closeTo(200, 0.001));
      expect(result.centerY, closeTo(200, 0.001));
    });

    test('超过原图对应边时钳制', () {
      final result = CropSelection.full(
        size,
      ).withTargetSize(5000, 5000, size, CropShape.rectangle);
      expect(result.width, 1000);
      expect(result.height, 800);
    });

    test('越界时整体向内平移至贴合', () {
      const selection = CropSelection(
        left: 900,
        top: 700,
        width: 100,
        height: 100,
      );
      final result = selection.withTargetSize(
        400,
        400,
        size,
        CropShape.rectangle,
      );
      expect(result.right, lessThanOrEqualTo(1000));
      expect(result.bottom, lessThanOrEqualTo(800));
      expect(result.width, 400);
      expect(result.height, 400);
    });

    test('圆形输入宽高不等时取外接正方形较小边', () {
      final result = CropSelection.full(
        size,
      ).withTargetSize(600, 300, size, CropShape.circle);
      expect(result.width, 300);
      expect(result.height, 300);
    });
  });

  group('手柄缩放（PRD 二.4 整数吸附前的小数坐标）', () {
    const base = CropSelection(left: 100, top: 100, width: 200, height: 200);

    test('拖右下角向右下扩展', () {
      final resized = base.resized(
        CropHandle.bottomRight,
        50,
        30,
        size,
        CropAspect.free,
        CropShape.rectangle,
      );
      expect(resized.left, 100);
      expect(resized.top, 100);
      expect(resized.width, 250);
      expect(resized.height, 230);
    });

    test('拖左上角时右下角固定', () {
      final resized = base.resized(
        CropHandle.topLeft,
        -50,
        -50,
        size,
        CropAspect.free,
        CropShape.rectangle,
      );
      expect(resized.right, 300);
      expect(resized.bottom, 300);
      expect(resized.width, 250);
      expect(resized.height, 250);
    });

    test('比例锁定时高度跟随宽度', () {
      final resized = base.resized(
        CropHandle.right,
        100,
        0,
        size,
        CropAspect.square,
        CropShape.rectangle,
      );
      expect(resized.width, closeTo(resized.height, 0.001));
      expect(resized.width, 300);
    });

    test('超出边界时等比缩回，不越界', () {
      final resized = base.resized(
        CropHandle.right,
        800,
        0,
        size,
        CropAspect.square,
        CropShape.rectangle,
      );
      expect(resized.right, lessThanOrEqualTo(1000));
      expect(resized.bottom, lessThanOrEqualTo(800));
      expect(resized.width, closeTo(resized.height, 0.001));
    });

    test('圆形手柄也强制 1:1', () {
      final resized = base.resized(
        CropHandle.bottom,
        0,
        50,
        size,
        CropAspect.free,
        CropShape.circle,
      );
      expect(resized.width, closeTo(resized.height, 0.001));
    });
  });
}
