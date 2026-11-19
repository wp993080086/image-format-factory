import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:pixel_forge/core/image/color_adjust.dart';

img.Image _solid(int r, int g, int b) {
  final image = img.Image(width: 16, height: 16, numChannels: 4);
  img.fill(image, color: img.ColorRgba8(r, g, b, 255));
  return image;
}

void main() {
  group('ColorAdjust 参数', () {
    test('默认全 0 即 isNoop', () {
      expect(const ColorAdjust().isNoop, isTrue);
    });

    test('copyWith 只改指定字段', () {
      const base = ColorAdjust();
      final next = base.copyWith(brightness: 30);
      expect(next.brightness, 30);
      expect(next.contrast, 0);
      expect(base.brightness, 0); // 不可变
    });
  });

  group('applyColorAdjust 像素效果', () {
    test('noop 返回同一对象，不产生拷贝', () {
      final src = _solid(100, 100, 100);
      expect(applyColorAdjust(src, const ColorAdjust()), same(src));
    });

    test('正亮度使像素变亮', () {
      final src = _solid(100, 100, 100);
      final out = applyColorAdjust(src, const ColorAdjust(brightness: 50));
      expect(out.getPixel(8, 8).r, greaterThan(100));
    });

    test('负亮度使像素变暗', () {
      final src = _solid(100, 100, 100);
      final out = applyColorAdjust(src, const ColorAdjust(brightness: -50));
      expect(out.getPixel(8, 8).r, lessThan(100));
    });

    test('饱和度 0 使彩色接近灰度', () {
      final src = _solid(200, 40, 60);
      final out = applyColorAdjust(src, const ColorAdjust(saturation: -100));
      final p = out.getPixel(8, 8);
      expect((p.r - p.g).abs(), lessThan(12));
    });

    test('色相偏移改变颜色', () {
      final src = _solid(200, 30, 30); // 红
      final out = applyColorAdjust(src, const ColorAdjust(hue: 120));
      final p = out.getPixel(8, 8);
      expect(p.g, greaterThan(src.getPixel(8, 8).g)); // 红转绿系
    });

    test('降噪半径参数生效但不崩溃', () {
      final src = _solid(80, 90, 100);
      final out = applyColorAdjust(src, const ColorAdjust(denoise: 40));
      expect(out.width, src.width);
      expect(out.height, src.height);
    });

    test('不修改入参', () {
      final src = _solid(100, 100, 100);
      final before = src.getPixel(8, 8).r;
      applyColorAdjust(src, const ColorAdjust(brightness: 50));
      expect(src.getPixel(8, 8).r, before);
    });
  });
}
