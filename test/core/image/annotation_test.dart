import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:pixel_forge/core/image/annotation.dart';

img.Image _canvas() {
  final image = img.Image(width: 100, height: 100, numChannels: 4);
  img.fill(image, color: img.ColorRgba8(0, 0, 0, 255));
  // 右上区域放一块白，便于马赛克检测
  img.fillRect(image, x1: 60, y1: 60, x2: 99, y2: 99, color: img.ColorRgba8(255, 255, 255, 255));
  return image;
}

int _changedPixels(img.Image a, img.Image b) {
  var n = 0;
  for (var y = 0; y < a.height; y++) {
    for (var x = 0; x < a.width; x++) {
      if (a.getPixel(x, y).r != b.getPixel(x, y).r) n++;
    }
  }
  return n;
}

void main() {
  group('标注合成', () {
    test('空标注返回同一对象', () {
      final src = _canvas();
      expect(applyAnnotations(src, const []), same(src));
    });

    test('七类标注均可合成且不崩溃', () {
      const specs = <Annotation>[
        Annotation(type: AnnotationType.text, x1: 5, y1: 5, x2: 0, y2: 0, text: 'AB'),
        Annotation(type: AnnotationType.line, x1: 10, y1: 10, x2: 40, y2: 40),
        Annotation(type: AnnotationType.arrow, x1: 10, y1: 50, x2: 40, y2: 50),
        Annotation(type: AnnotationType.rectangle, x1: 50, y1: 10, x2: 80, y2: 40),
        Annotation(type: AnnotationType.circle, x1: 20, y1: 20, x2: 60, y2: 60),
        Annotation(type: AnnotationType.ellipse, x1: 10, y1: 60, x2: 50, y2: 90),
        Annotation(type: AnnotationType.mosaic, x1: 60, y1: 60, x2: 99, y2: 99, mosaicBlock: 10),
      ];
      final out = applyAnnotations(_canvas(), specs);
      expect(out.width, 100);
      expect(out.height, 100);
    });

    test('每条标注确实改变了像素', () {
      for (final type in AnnotationType.values) {
        final src = _canvas();
        final isMosaic = type == AnnotationType.mosaic;
        final a = Annotation(
          type: type,
          // 马赛克需跨越黑/白边界才有可见变化；其余类型任意框
          x1: isMosaic ? 50 : 10,
          y1: isMosaic ? 50 : 10,
          x2: isMosaic ? 75 : 50,
          y2: isMosaic ? 75 : 50,
          text: 'AB',
          colorArgb: 0xFFFFFF00,
        );
        final out = applyAnnotations(src, [a]);
        expect(_changedPixels(src, out), greaterThan(0), reason: '$type 应改变像素');
      }
    });

    test('矢量数据不修改入参', () {
      final src = _canvas();
      final before = src.getPixel(30, 30).r;
      applyAnnotations(src, const [
        Annotation(type: AnnotationType.line, x1: 10, y1: 10, x2: 50, y2: 50),
      ]);
      expect(src.getPixel(30, 30).r, before);
    });

    test('马赛克把白色区域打码为混合色', () {
      final src = _canvas();
      expect(src.getPixel(80, 80).r, 255);
      final out = applyAnnotations(src, const [
        Annotation(type: AnnotationType.mosaic, x1: 50, y1: 50, x2: 70, y2: 70, mosaicBlock: 40),
      ]);
      // 打码块跨黑(0)/白(255)边界，平均值应落在中间
      expect(out.getPixel(65, 65).r, lessThan(255));
      expect(out.getPixel(65, 65).r, greaterThan(0));
    });
  });
}
