import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:pixel_forge/core/image/annotation.dart';
import 'package:pixel_forge/core/image/cjk_text.dart';
import 'package:pixel_forge/core/image/resize_apply.dart';
import 'package:pixel_forge/core/image/resize_geometry.dart';

img.Image _canvas() {
  final image = img.Image(width: 100, height: 100, numChannels: 4);
  img.fill(image, color: img.ColorRgba8(0, 0, 0, 255));
  // 右上区域放一块白，便于马赛克检测
  img.fillRect(
    image,
    x1: 60,
    y1: 60,
    x2: 99,
    y2: 99,
    color: img.ColorRgba8(255, 255, 255, 255),
  );
  return image;
}

/// 左半黑、x=58~62 处一条白竖条，用于核对几何映射后标注与像素是否对齐。
img.Image _markedSource() {
  final image = img.Image(width: 100, height: 100, numChannels: 3);
  img.fill(image, color: img.ColorRgb8(0, 0, 0));
  img.fillRect(
    image,
    x1: 58,
    y1: 40,
    x2: 62,
    y2: 60,
    color: img.ColorRgb8(255, 255, 255),
  );
  return image;
}

int _brightestX(img.Image image, int y) {
  var bestX = -1;
  var best = -1;
  for (var x = 0; x < image.width; x++) {
    final value = image.getPixel(x, y).r.toInt();
    if (value > best) {
      best = value;
      bestX = x;
    }
  }
  return bestX;
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

void _expectSnowGray(num g) {
  expect(g, greaterThanOrEqualTo(48));
  expect(g, lessThanOrEqualTo(208));
}

void main() {
  group('标注合成', () {
    test('空标注返回同一对象', () {
      final src = _canvas();
      expect(applyAnnotations(src, const []), same(src));
    });

    test('中文文字标注渲染出字形，copyWith 保留其余字段', () {
      final src = _canvas();
      const a = Annotation(
        type: AnnotationType.text,
        x1: 4,
        y1: 4,
        x2: 0,
        y2: 0,
        text: '标注',
        fontSize: 24,
        colorArgb: 0xFFFFFFFF,
      );
      final out = applyAnnotations(src, [a]);
      expect(_changedPixels(src, out), greaterThan(10), reason: '中文文字应画出字形');

      final moved = a.copyWith(x1: 20, y1: 30);
      expect(moved.x1, 20);
      expect(moved.y1, 30);
      expect(moved.text, '标注');
      expect(moved.fontSize, 24);
      expect(moved.type, AnnotationType.text);
    });

    test('七类标注均可合成且不崩溃', () {
      const specs = <Annotation>[
        Annotation(
          type: AnnotationType.text,
          x1: 5,
          y1: 5,
          x2: 0,
          y2: 0,
          text: 'AB',
        ),
        Annotation(type: AnnotationType.line, x1: 10, y1: 10, x2: 40, y2: 40),
        Annotation(type: AnnotationType.arrow, x1: 10, y1: 50, x2: 40, y2: 50),
        Annotation(
          type: AnnotationType.rectangle,
          x1: 50,
          y1: 10,
          x2: 80,
          y2: 40,
        ),
        Annotation(type: AnnotationType.circle, x1: 20, y1: 20, x2: 60, y2: 60),
        Annotation(
          type: AnnotationType.ellipse,
          x1: 10,
          y1: 60,
          x2: 50,
          y2: 90,
        ),
        Annotation(
          type: AnnotationType.mosaic,
          x1: 60,
          y1: 60,
          x2: 99,
          y2: 99,
          mosaicBlock: 10,
        ),
      ];
      final out = applyAnnotations(_canvas(), specs);
      expect(out.width, 100);
      expect(out.height, 100);
    });

    test('每条标注确实改变了像素', () {
      for (final type in AnnotationType.values) {
        final src = _canvas();
        final isMosaic = type == AnnotationType.mosaic;
        final isBrush = type == AnnotationType.brush;
        final a = Annotation(
          type: type,
          // 马赛克需跨越黑/白边界才有可见变化；其余类型任意框
          x1: isMosaic ? 50 : 10,
          y1: isMosaic ? 50 : 10,
          x2: isMosaic ? 75 : 50,
          y2: isMosaic ? 75 : 50,
          text: 'AB',
          colorArgb: 0xFFFFFF00,
          // 涂抹：一条跨黑/白边界的轨迹；块 16 使统计块跨过 x=60/y=60
          points: isBrush ? const [50, 50, 70, 50, 70, 70, 50, 70] : const [],
          brushRadius: 8,
          mosaicBlock: isBrush ? 16 : 12,
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

    test('矩形马赛克用固定雪花点盖住区域，不依赖底图颜色', () {
      final src = _canvas();
      expect(src.getPixel(80, 80).r, 255); // 原为白区
      final out = applyAnnotations(src, const [
        Annotation(
          type: AnnotationType.mosaic,
          x1: 50,
          y1: 50,
          x2: 70,
          y2: 70,
          mosaicBlock: 40,
        ),
      ]);
      // 雪花灰度固定落在 48~208，与底图黑白都不同
      final g = out.getPixel(65, 65).r;
      _expectSnowGray(g);
      expect(g, lessThan(255));
      expect(g, greaterThan(0));
    });

    test('雪花点确定性：同块同色、块间有变化', () {
      expect(snowGray(3, 5), snowGray(3, 5), reason: '同一块坐标必须同色');
      final colors = {
        for (var bx = 0; bx < 8; bx++)
          for (var by = 0; by < 8; by++) snowGray(bx, by),
      };
      expect(colors.length, greaterThan(1), reason: '不同块应有不同雪花灰度');
      for (final g in colors) {
        _expectSnowGray(g);
      }
    });

    test('同一雪花图案盖在不同底图上，结果像素完全一致', () {
      final black = img.Image(width: 40, height: 40, numChannels: 4);
      img.fill(black, color: img.ColorRgba8(0, 0, 0, 255));
      final white = img.Image(width: 40, height: 40, numChannels: 4);
      img.fill(white, color: img.ColorRgba8(255, 255, 255, 255));
      const a = Annotation(
        type: AnnotationType.mosaic,
        x1: 4,
        y1: 4,
        x2: 36,
        y2: 36,
        mosaicBlock: 8,
      );
      final outBlack = applyAnnotations(black, [a]);
      final outWhite = applyAnnotations(white, [a]);
      // 打码区完全被雪花覆盖，与底图无关
      expect(outBlack.getPixel(20, 20).r, outWhite.getPixel(20, 20).r);
      // 区外保持各自底图
      expect(outBlack.getPixel(1, 1).r, 0);
      expect(outWhite.getPixel(1, 1).r, 255);
    });
  });
  group('标注坐标变换（裁剪+缩放后合成）', () {
    const a = Annotation(
      type: AnnotationType.rectangle,
      x1: 10,
      y1: 20,
      x2: 50,
      y2: 60,
      strokeWidth: 4,
    );

    test('无裁剪无缩放返回原列表对象', () {
      final list = [a];
      expect(
        transformAnnotations(list, cropX: 0, cropY: 0, cropW: 100, cropH: 100),
        same(list),
      );
    });

    test('裁剪偏移后坐标平移，线宽不变', () {
      final out = transformAnnotations(
        [a],
        cropX: 10,
        cropY: 20,
        cropW: 80,
        cropH: 80,
      ).single;
      expect(out.x1, 0);
      expect(out.y1, 0);
      expect(out.x2, 40);
      expect(out.y2, 40);
      expect(out.strokeWidth, 4, reason: '线宽不应被缩放');
    });

    test('缩放后坐标按比例映射', () {
      final out = transformAnnotations(
        [a],
        cropX: 0,
        cropY: 0,
        cropW: 100,
        cropH: 100,
        resize: const ResizeTarget(width: 200, height: 50),
      ).single;
      expect(out.x1, 20);
      expect(out.y1, 10);
      expect(out.x2, 100);
      expect(out.y2, 30);
    });

    test('cover：标注映射与裁剪后像素位置一致', () {
      const target = ResizeTarget(
        width: 80,
        height: 100,
        mode: ResizeMode.cover,
      );
      const mark = Annotation(
        type: AnnotationType.rectangle,
        x1: 60,
        y1: 50,
        x2: 61,
        y2: 51,
      );
      final mapped = transformAnnotations(
        const [mark],
        cropX: 0,
        cropY: 0,
        cropW: 100,
        cropH: 100,
        resize: target,
      ).single;
      expect(mapped.x1, 50, reason: 'cover 需先裁掉源图左右各 10px');

      final resized = applyResize(_markedSource(), target);
      expect(
        _brightestX(resized, 50),
        closeTo(mapped.x1, 2),
        reason: '标注位置应与白块在输出图中的位置一致',
      );
    });

    test('contain：标注映射与留白后像素位置一致', () {
      const target = ResizeTarget(
        width: 200,
        height: 100,
        mode: ResizeMode.contain,
      );
      const mark = Annotation(
        type: AnnotationType.rectangle,
        x1: 60,
        y1: 50,
        x2: 61,
        y2: 51,
      );
      final mapped = transformAnnotations(
        const [mark],
        cropX: 0,
        cropY: 0,
        cropW: 100,
        cropH: 100,
        resize: target,
      ).single;
      expect(mapped.x1, 110, reason: 'contain 需加上 50px 左边留白');

      final resized = applyResize(_markedSource(), target);
      expect(
        _brightestX(resized, 50),
        closeTo(mapped.x1, 2),
        reason: '标注位置应与白块在输出图中的位置一致',
      );
    });
  });

  group('涂抹打码（v0.6）', () {
    // 一条沿 y=70（白区行）横跨 x=60 黑白边界的轨迹；mosaicBlock=16 使块跨边界。
    const stroke = Annotation(
      type: AnnotationType.brush,
      x1: 45,
      y1: 70,
      x2: 95,
      y2: 70,
      points: [45, 70, 70, 70, 95, 70],
      brushRadius: 8,
      mosaicBlock: 16,
    );

    test('马赛克模式改变轨迹覆盖处的像素，覆盖处变雪花灰度', () {
      final src = _canvas();
      final out = applyAnnotations(src, [stroke]);
      // (60,70) 被雪花点覆盖，灰度落在固定范围 48~208
      final pixel = out.getPixel(60, 70).r;
      _expectSnowGray(pixel);
      expect(_changedPixels(src, out), greaterThan(0));
    });

    test('模糊模式同样改变覆盖处像素', () {
      final src = _canvas();
      final out = applyAnnotations(src, [
        stroke.copyWith(brushMode: BrushMode.blur),
      ]);
      expect(_changedPixels(src, out), greaterThan(0));
    });

    test('涂抹不修改入参', () {
      final src = _canvas();
      final before = src.getPixel(50, 50).r;
      applyAnnotations(src, [stroke]);
      expect(src.getPixel(50, 50).r, before);
    });

    test('单点涂抹也生效（点击涂一个圆点）', () {
      final src = _canvas();
      // 点在黑白边界附近，半径覆盖两侧才有可见变化
      final dot = stroke.copyWith(points: const [58, 70]);
      final out = applyAnnotations(src, [dot]);
      expect(out.getPixel(58, 70).r, lessThan(255), reason: '白区圆点应被混合色覆盖');
    });

    test('空轨迹不产生任何改动', () {
      final src = _canvas();
      final out = applyAnnotations(src, [stroke.copyWith(points: const [])]);
      expect(_changedPixels(src, out), 0);
    });

    test('坐标变换时轨迹点随裁剪+缩放映射，笔刷半径不变', () {
      final out = transformAnnotations(
        const [stroke],
        cropX: 10,
        cropY: 10,
        cropW: 100,
        cropH: 100,
        resize: const ResizeTarget(width: 200, height: 200),
      ).single;
      // 点 (45,70) 在裁剪后为 (35,60)，再 ×2 → (70,120)
      expect(out.points[0], 70);
      expect(out.points[1], 120);
      expect(out.brushRadius, 8, reason: '笔刷半径不应被缩放');
    });
  });

  test('CjkText 度量给预览提供与导出一致的框和基线', () {
    const text = '你好世界';
    const size = 24;
    expect(CjkText.measureWidth(text, size), 96);
    expect(CjkText.measureInkHeight(text, size), 31);
    expect(
      CjkText.maxYOffset(text, size),
      8,
      reason: '预览文字纵向下移量应与点阵字形的 yOffset 一致',
    );
    expect(CjkText.maxYOffset(text, 48), 16, reason: '字号翻倍时偏移同比放大');
  });
}
