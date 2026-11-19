import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:pixel_forge/core/image/watermark.dart';

img.Image _black() {
  final image = img.Image(width: 120, height: 80, numChannels: 4);
  img.fill(image, color: img.ColorRgba8(0, 0, 0, 255));
  return image;
}

void main() {
  group('TextWatermark', () {
    test('空文字或透明视为空水印', () {
      expect(const TextWatermark(text: '').isEmpty, isTrue);
      expect(const TextWatermark(text: 'A', opacity: 0).isEmpty, isTrue);
      expect(const TextWatermark(text: 'A').isEmpty, isFalse);
    });

    test('noop 返回同一对象', () {
      final src = _black();
      expect(applyTextWatermark(src, const TextWatermark(text: '')), same(src));
    });

    test('ASCII 水印渲染出非黑像素，且不修改入参', () {
      final src = _black();
      const w = TextWatermark(
        text: 'WM',
        fontSize: 48,
        colorArgb: 0xFFFFFFFF,
        opacity: 100,
        position: WatermarkPosition.center,
      );
      final out = applyTextWatermark(src, w);
      var changed = 0;
      for (var y = 0; y < out.height; y++) {
        for (var x = 0; x < out.width; x++) {
          if (out.getPixel(x, y).r > 10) changed++;
        }
      }
      expect(changed, greaterThan(0));
      // 入参中心仍是黑
      expect(src.getPixel(60, 40).r, 0);
    });

    test('中文字符不崩溃（位图字体不含中文，跳过渲染）', () {
      final src = _black();
      final out = applyTextWatermark(
        src,
        const TextWatermark(text: '水印', fontSize: 48),
      );
      expect(out.width, src.width);
    });

    test('旋转不崩溃且保持画布尺寸', () {
      final src = _black();
      final out = applyTextWatermark(
        src,
        const TextWatermark(text: 'ABC', fontSize: 24, rotation: 45),
      );
      expect(out.width, src.width);
      expect(out.height, src.height);
    });

    test('四角与居中位置均能合成', () {
      for (final pos in WatermarkPosition.values) {
        final out = applyTextWatermark(
          _black(),
          TextWatermark(text: 'X', fontSize: 48, position: pos),
        );
        expect(out.width, 120, reason: '$pos');
        expect(out.height, 80, reason: '$pos');
      }
    });
  });
}
