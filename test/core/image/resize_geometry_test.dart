import 'package:flutter_test/flutter_test.dart';
import 'package:image_format_factory/core/image/image_header_probe.dart';
import 'package:image_format_factory/core/image/resize_geometry.dart';

void main() {
  const source = ImageDimensions(800, 600);

  group('clampResizeTarget', () {
    test('合法输入原样返回', () {
      final clamp = clampResizeTarget(source, 400, 300);
      expect(clamp.width, 400);
      expect(clamp.height, 300);
      expect(clamp.clamped, isFalse);
    });

    test('单边超过 4 倍被截断', () {
      final clamp = clampResizeTarget(source, 3201, 600);
      expect(clamp.width, 3200);
      expect(clamp.height, 600);
      expect(clamp.edgeLimited, isTrue);
      expect(clamp.pixelsLimited, isFalse);
    });

    test('总像素超过 4000 万时等比缩小', () {
      // 2000×2000 原图放大 4 倍 = 6400 万像素，超出 4000 万上限
      const big = ImageDimensions(2000, 2000);
      final clamp = clampResizeTarget(big, 8000, 8000);
      expect(clamp.width * clamp.height, lessThanOrEqualTo(maxResizePixels));
      expect(clamp.pixelsLimited, isTrue);
      // 等比缩小后仍是正方形
      expect(clamp.width, clamp.height);
      expect(clamp.width, greaterThan(6000));
    });

    test('小图放大上限为原图对应边的 4 倍', () {
      final clamp = clampResizeTarget(const ImageDimensions(10, 10), 100, 100);
      expect(clamp.edgeLimited, isTrue);
      expect(clamp.pixelsLimited, isFalse);
      expect(clamp.width, 40);
    });

    test('非正数被抬到 1', () {
      final clamp = clampResizeTarget(source, 0, -5);
      expect(clamp.width, 1);
      expect(clamp.height, 1);
      expect(clamp.edgeLimited, isTrue);
    });
  });

  group('coverSourceRect', () {
    test('目标更方：裁掉左右，居中', () {
      final rect = coverSourceRect(source, 400, 400);
      expect(rect.width, 600);
      expect(rect.height, 600);
      expect(rect.x, 100);
      expect(rect.y, 0);
    });

    test('目标更扁：裁掉上下，居中', () {
      final rect = coverSourceRect(source, 800, 300);
      expect(rect.width, 800);
      expect(rect.height, 300);
      expect(rect.x, 0);
      expect(rect.y, 150);
    });

    test('比例一致时裁切区等于整图', () {
      final rect = coverSourceRect(source, 400, 300);
      expect(rect.width, 800);
      expect(rect.height, 600);
      expect(rect.x, 0);
      expect(rect.y, 0);
    });
  });

  group('containLayout', () {
    test('源更宽：内容缩到宽度贴合，上下留白', () {
      final layout = containLayout(source, 400, 400);
      expect(layout.width, 400);
      expect(layout.height, 300);
      expect(layout.dx, 0);
      expect(layout.dy, 50);
    });

    test('源更高：内容缩到高度贴合，左右留白', () {
      final layout = containLayout(const ImageDimensions(100, 200), 200, 200);
      expect(layout.width, 100);
      expect(layout.height, 200);
      expect(layout.dx, 50);
      expect(layout.dy, 0);
    });

    test('比例一致时铺满无留白', () {
      final layout = containLayout(source, 400, 300);
      expect(layout.width, 400);
      expect(layout.height, 300);
      expect(layout.dx, 0);
      expect(layout.dy, 0);
    });
  });

  group('ResizeTarget', () {
    test('透明底判定只看 alpha 字节', () {
      const transparent = ResizeTarget(width: 10, height: 10);
      const white = ResizeTarget(
        width: 10,
        height: 10,
        backgroundArgb: 0xFFFFFFFF,
      );
      expect(transparent.isTransparent, isTrue);
      expect(white.isTransparent, isFalse);
    });

    test('同尺寸视为未变更', () {
      const target = ResizeTarget(width: 800, height: 600);
      expect(target.differsFrom(source), isFalse);
      expect(target.copyWith(width: 400).differsFrom(source), isTrue);
    });

    test('scaleLabel 以宽度比例为基准', () {
      expect(scaleLabel(source, 400, 300), '50%');
      expect(scaleLabel(source, 1600, 1200), '200%');
    });
  });
}
