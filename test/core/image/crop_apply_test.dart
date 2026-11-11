import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:pixel_forge/core/image/crop_apply.dart';
import 'package:pixel_forge/core/image/crop_selection.dart';

/// 造一张黑底 + (10,10)-(29,29) 红块的四通道图。
img.Image _marker({int width = 100, int height = 80}) {
  final image = img.Image(width: width, height: height, numChannels: 4);
  img.fill(image, color: img.ColorRgba8(0, 0, 0, 255));
  for (var y = 10; y < 30; y++) {
    for (var x = 10; x < 30; x++) {
      image.setPixelRgba(x, y, 255, 0, 0, 255);
    }
  }
  return image;
}

void main() {
  group('矩形裁剪（PRD 二章注：直接像素拷贝）', () {
    test('输出尺寸等于裁剪区尺寸', () {
      final cropped = applyCrop(
        _marker(),
        const CropArea(x: 10, y: 10, width: 20, height: 20),
      );
      expect(cropped.width, 20);
      expect(cropped.height, 20);
    });

    test('像素内容与源图对应区域一致', () {
      final cropped = applyCrop(
        _marker(),
        const CropArea(x: 10, y: 10, width: 20, height: 20),
      );
      // 裁剪区内全部落在红块上
      for (var y = 0; y < 20; y++) {
        for (var x = 0; x < 20; x++) {
          final p = cropped.getPixel(x, y);
          expect(p.r, 255, reason: '($x,$y) 应保留红色');
          expect(p.g, 0);
        }
      }
    });

    test('偏移裁剪取到红块之外的黑区', () {
      final cropped = applyCrop(
        _marker(),
        const CropArea(x: 0, y: 0, width: 10, height: 10),
      );
      expect(cropped.getPixel(0, 0).r, 0);
    });

    test('裁剪区越界时钳制到图片内', () {
      final cropped = applyCrop(
        _marker(),
        const CropArea(x: -20, y: -20, width: 40, height: 40),
      );
      expect(cropped.width, 40);
      expect(cropped.height, 40);
    });

    test('裁剪区超出右边时收敛到剩余宽度', () {
      final cropped = applyCrop(
        _marker(),
        const CropArea(x: 90, y: 70, width: 50, height: 50),
      );
      expect(cropped.width, 10);
      expect(cropped.height, 10);
    });

    test('输出统一为 4 通道', () {
      final rgb = img.Image(width: 40, height: 40, numChannels: 3);
      img.fill(rgb, color: img.ColorRgb8(10, 20, 30));
      final cropped = applyCrop(
        rgb,
        const CropArea(x: 0, y: 0, width: 20, height: 20),
      );
      expect(cropped.numChannels, 4);
    });
  });

  group('圆形遮罩（PRD 二.7：方形画布 + 圆外透明）', () {
    img.Image cropCircle(int size) {
      final source = img.Image(width: size, height: size, numChannels: 4);
      img.fill(source, color: img.ColorRgba8(200, 100, 50, 255));
      return applyCrop(
        source,
        CropArea(x: 0, y: 0, width: size, height: size),
        circle: true,
      );
    }

    test('输出仍为方形画布', () {
      final result = cropCircle(100);
      expect(result.width, 100);
      expect(result.height, 100);
    });

    test('圆心区域 alpha 保持不透明', () {
      final result = cropCircle(100);
      expect(result.getPixel(50, 50).a, 255);
    });

    test('四角完全透明', () {
      final result = cropCircle(100);
      for (final point in [(0, 0), (99, 0), (0, 99), (99, 99)]) {
        final pixel = result.getPixel(point.$1, point.$2);
        expect(pixel.a, 0, reason: '角落 ${point.$1},${point.$2} 应透明');
      }
    });

    test('边缘存在半透明过渡带（抗锯齿生效）', () {
      final result = cropCircle(100);
      var found = false;
      for (var y = 0; y < 100 && !found; y++) {
        for (var x = 0; x < 100; x++) {
          final a = result.getPixel(x, y).a;
          if (a > 0 && a < 255) {
            found = true;
            break;
          }
        }
      }
      expect(found, isTrue, reason: '圆形边界应有 1px 抗锯齿过渡');
    });

    test('圆外像素颜色未被清零，仅 alpha 归零', () {
      final result = cropCircle(100);
      final corner = result.getPixel(0, 0);
      expect(corner.r, 200);
      expect(corner.a, 0);
    });
  });
}
