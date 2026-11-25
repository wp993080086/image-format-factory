import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:image_format_factory/core/image/alpha_scan.dart';

img.Image _rgba(int width, int height, int alpha) {
  final image = img.Image(width: width, height: height, numChannels: 4);
  img.fill(image, color: img.ColorRgba8(10, 20, 30, alpha));
  return image;
}

void main() {
  group('hasSemiTransparentPixels', () {
    test('全不透明返回 false', () {
      expect(hasSemiTransparentPixels(_rgba(8, 8, 255)), isFalse);
    });

    test('全透明返回 false（透明不等于半透明）', () {
      expect(hasSemiTransparentPixels(_rgba(8, 8, 0)), isFalse);
    });

    test('存在部分透明像素返回 true', () {
      expect(hasSemiTransparentPixels(_rgba(8, 8, 128)), isTrue);
    });

    test('单个半透明像素即可命中', () {
      final image = _rgba(16, 16, 255);
      image.setPixelRgba(5, 5, 10, 20, 30, 1);
      expect(hasSemiTransparentPixels(image), isTrue);
    });

    test('无 Alpha 通道的源直接返回 false', () {
      final rgb = img.Image(width: 8, height: 8, numChannels: 3);
      img.fill(rgb, color: img.ColorRgb8(1, 2, 3));
      expect(rgb.hasAlpha, isFalse);
      expect(hasSemiTransparentPixels(rgb), isFalse);
    });
  });
}
