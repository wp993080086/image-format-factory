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

    test('中文水印渲染出像素（内嵌 Noto Sans SC 点阵）', () {
      final src = _black();
      const w = TextWatermark(
        text: '水印',
        fontSize: 24,
        colorArgb: 0xFFFFFFFF,
        position: WatermarkPosition.center,
      );
      final out = applyTextWatermark(src, w);
      var changed = 0;
      for (var y = 0; y < out.height; y++) {
        for (var x = 0; x < out.width; x++) {
          if (out.getPixel(x, y).r > 10) changed++;
        }
      }
      expect(changed, greaterThan(20), reason: '中文应实际画出字形');
      expect(src.getPixel(60, 40).r, 0, reason: '不修改入参');
    });

    test('中文按字号缩放：48px 比 24px 画出更多像素', () {
      int changedAt(int size) {
        final big = img.Image(width: 300, height: 200, numChannels: 4);
        img.fill(big, color: img.ColorRgba8(0, 0, 0, 255));
        final out = applyTextWatermark(
          big,
          TextWatermark(
            text: '中文',
            fontSize: size,
            position: WatermarkPosition.center,
          ),
        );
        var n = 0;
        for (final p in out) {
          if (p.r > 10) n++;
        }
        return n;
      }

      expect(changedAt(48), greaterThan(changedAt(24)));
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

    test('全屏重复比单点画出更多水印像素', () {
      int changed(bool repeat) {
        final src = img.Image(width: 400, height: 300, numChannels: 4);
        img.fill(src, color: img.ColorRgba8(0, 0, 0, 255));
        final out = applyTextWatermark(
          src,
          TextWatermark(
            text: 'WM',
            fontSize: 24,
            colorArgb: 0xFFFFFFFF,
            position: WatermarkPosition.center,
            repeat: repeat,
          ),
        );
        var n = 0;
        for (final p in out) {
          if (p.r > 10) n++;
        }
        return n;
      }

      expect(
        changed(true),
        greaterThan(changed(false) * 2),
        reason: '平铺应在多处重复出现',
      );
    });

    test('copyWith 保留未指定字段', () {
      const base = TextWatermark(
        text: '原',
        fontSize: 30,
        colorArgb: 0xFFFF0000,
        opacity: 60,
        position: WatermarkPosition.topLeft,
        repeat: true,
      );
      final next = base.copyWith(text: '新');
      expect(next.text, '新');
      expect(next.fontSize, 30);
      expect(next.colorArgb, 0xFFFF0000);
      expect(next.opacity, 60);
      expect(next.position, WatermarkPosition.topLeft);
      expect(next.repeat, isTrue);
    });
  });
}
