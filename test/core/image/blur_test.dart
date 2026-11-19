import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:pixel_forge/core/image/blur.dart';

img.Image _splitCanvas() {
  final image = img.Image(width: 100, height: 100, numChannels: 3);
  img.fill(image, color: img.ColorRgb8(0, 0, 0));
  img.fillRect(
    image,
    x1: 50,
    y1: 0,
    x2: 99,
    y2: 99,
    color: img.ColorRgb8(255, 255, 255),
  );
  return image;
}

void main() {
  group('模糊半径换算', () {
    test('强度 0 返回半径 0', () {
      expect(blurRadiusFor(0, 1000), 0);
      expect(blurRadiusFor(-5, 1000), 0);
    });

    test('半径随强度递增，且随短边缩放', () {
      final small = blurRadiusFor(100, 500);
      final large = blurRadiusFor(100, 2000);
      expect(small, greaterThan(0));
      expect(large, greaterThan(small));
    });

    test('半径有上限，避免超大图导出过慢', () {
      expect(blurRadiusFor(100, 100000), 80);
      // 超范围强度按 100 处理：与传 100 的结果一致
      expect(blurRadiusFor(1000, 1000), blurRadiusFor(100, 1000));
    });
  });

  group('整图模糊', () {
    test('强度 0 原样返回入参对象（零拷贝）', () {
      final src = _splitCanvas();
      expect(applyGlobalBlur(src, 0), same(src));
    });

    test('模糊把黑白硬边界抹开', () {
      final src = _splitCanvas();
      expect(src.getPixel(49, 50).r, 0);
      expect(src.getPixel(50, 50).r, 255);
      final out = applyGlobalBlur(src, 60);
      // 边界两侧不再是非黑即白，出现中间灰
      final left = out.getPixel(49, 50).r;
      final right = out.getPixel(50, 50).r;
      expect(left, greaterThan(0));
      expect(right, lessThan(255));
    });

    test('不修改入参', () {
      final src = _splitCanvas();
      final before = src.getPixel(50, 50).r;
      applyGlobalBlur(src, 80);
      expect(src.getPixel(50, 50).r, before);
    });
  });
}
