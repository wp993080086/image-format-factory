import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:image_format_factory/core/image/resize_apply.dart';
import 'package:image_format_factory/core/image/resize_geometry.dart';

/// 纯色图，4 通道。
img.Image _solid(int width, int height, img.Color color) {
  final image = img.Image(width: width, height: height, numChannels: 4);
  img.fill(image, color: color);
  return image;
}

void main() {
  group('applyResize / stretch', () {
    test('强制缩放到目标尺寸，忽略原比例', () {
      final result = applyResize(
        _solid(200, 100, img.ColorRgb8(200, 30, 30)),
        const ResizeTarget(width: 50, height: 50),
      );
      expect(result.width, 50);
      expect(result.height, 50);
    });

    test('目标尺寸与源一致时直接返回原对象', () {
      final source = _solid(64, 32, img.ColorRgb8(0, 0, 0));
      final result = applyResize(
        source,
        const ResizeTarget(width: 64, height: 32),
      );
      expect(identical(result, source), isTrue);
    });
  });

  group('applyResize / cover', () {
    test('居中裁切：保留中心区域，两侧被丢弃', () {
      // 左半红、右半蓝；目标为正方形时裁的是中间 200px 宽的竖条，
      // 因此结果左边缘应来自红色、右边缘来自蓝色。
      final source = img.Image(width: 800, height: 200, numChannels: 4);
      for (var y = 0; y < 200; y++) {
        for (var x = 0; x < 800; x++) {
          final left = x < 400;
          source.setPixelRgba(x, y, left ? 255 : 0, 0, left ? 0 : 255, 255);
        }
      }

      final result = applyResize(
        source,
        const ResizeTarget(width: 200, height: 200, mode: ResizeMode.cover),
      );
      expect(result.width, 200);
      expect(result.height, 200);
      expect(result.getPixel(2, 100).r, greaterThan(200));
      expect(result.getPixel(197, 100).b, greaterThan(200));
    });
  });

  group('applyResize / contain', () {
    test('透明底：留白区域 alpha 为 0', () {
      final result = applyResize(
        _solid(400, 200, img.ColorRgb8(10, 200, 10)),
        const ResizeTarget(width: 400, height: 400, mode: ResizeMode.contain),
      );
      expect(result.width, 400);
      expect(result.height, 400);
      // 上下各留 100px
      expect(result.getPixel(200, 10).a, 0);
      expect(result.getPixel(200, 200).a, 255);
    });

    test('实色底：留白区域为指定底色', () {
      final result = applyResize(
        _solid(400, 200, img.ColorRgb8(10, 200, 10)),
        const ResizeTarget(
          width: 400,
          height: 400,
          mode: ResizeMode.contain,
          backgroundArgb: 0xFFFFFFFF,
        ),
      );
      final pad = result.getPixel(200, 10);
      expect(pad.r, 255);
      expect(pad.g, 255);
      expect(pad.b, 255);
      expect(pad.a, 255);
    });

    test('比例一致时不产生留白画布', () {
      final source = _solid(400, 200, img.ColorRgb8(0, 0, 0));
      final result = applyResize(
        source,
        const ResizeTarget(width: 200, height: 100, mode: ResizeMode.contain),
      );
      expect(result.width, 200);
      expect(result.height, 100);
      expect(result.getPixel(0, 0).a, 255);
    });
  });

  test('索引色源可正常重采样（不被强制降为最近邻）', () {
    // quantize 产出的就是带调色板的索引色图，等价于 PNG-8 源
    final indexed = img.quantize(
      _solid(64, 64, img.ColorRgb8(30, 120, 210)),
      numberOfColors: 8,
    );
    expect(indexed.hasPalette, isTrue);

    final result = applyResize(
      indexed,
      const ResizeTarget(width: 32, height: 32),
    );
    expect(result.width, 32);
    expect(result.height, 32);
    expect(result.getPixel(16, 16).b, greaterThan(150));
  });
}
