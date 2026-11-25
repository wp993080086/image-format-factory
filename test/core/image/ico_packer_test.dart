import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:image_format_factory/core/image/ico_packer.dart';

/// 纯色 RGBA 源图。
img.Image _rgba(
  int w,
  int h, {
  int r = 200,
  int g = 60,
  int b = 60,
  int a = 255,
}) {
  final image = img.Image(width: w, height: h, numChannels: 4);
  img.fill(image, color: img.ColorRgba8(r, g, b, a));
  return image;
}

void main() {
  group('尺寸矩阵（PRD 一.4）', () {
    test('正方形原图：≤256 且 ≤边长的尺寸全部可用', () {
      expect(defaultIcoSizes(width: 512, height: 512), [
        16,
        32,
        48,
        64,
        128,
        256,
      ]);
    });

    test('非方形原图以较短边判定，长边不参与', () {
      expect(defaultIcoSizes(width: 800, height: 200), [16, 32, 48, 64, 128]);
      expect(canRenderIcoSize(256, width: 800, height: 200), isFalse);
    });

    test('小于最小候选尺寸的原图 → 无可用尺寸', () {
      expect(defaultIcoSizes(width: 10, height: 10), isEmpty);
    });

    test('超过 256 的尺寸一律不可用（库硬上限）', () {
      expect(canRenderIcoSize(512, width: 1024, height: 1024), isFalse);
    });
  });

  group('逐尺寸重采样分档（PRD 三.3）', () {
    test('<64px 用 average，≥64px 用 cubic', () {
      expect(interpolationForIcoSize(16), img.Interpolation.average);
      expect(interpolationForIcoSize(48), img.Interpolation.average);
      expect(interpolationForIcoSize(64), img.Interpolation.cubic);
      expect(interpolationForIcoSize(256), img.Interpolation.cubic);
    });
  });

  group('packIco', () {
    test('多尺寸打包为单文件，每项尺寸与勾选值一致', () {
      final packed = packIco(_rgba(512, 512), [16, 32, 256])!;
      expect(packed.sizes, [16, 32, 256]);
      // ICO 文件头：reserved=0, type=1
      expect(packed.bytes.sublist(0, 4), [0, 0, 1, 0]);

      final ico = img.decodeIco(packed.bytes)!;
      expect(ico.numFrames, 3);
      expect(ico.frames.map((f) => f.width), [16, 32, 256]);
      expect(ico.frames.map((f) => f.height), [16, 32, 256]);
    });

    test('尺寸升序排列且去重', () {
      final packed = packIco(_rgba(512, 512), [256, 16, 16, 32])!;
      expect(packed.sizes, [16, 32, 256]);
    });

    test('放大尺寸被剔除，不产生越界导出', () {
      final packed = packIco(_rgba(100, 100), [16, 32, 128, 256])!;
      expect(packed.sizes, [16, 32]);
    });

    test('全部尺寸不可生成 → null', () {
      expect(packIco(_rgba(100, 100), [128, 256]), isNull);
      expect(packIco(_rgba(512, 512), [512]), isNull);
    });

    test('透明通道保留（PNG → ICO）', () {
      final packed = packIco(_rgba(512, 512, a: 0), [256])!;
      final frame = img.decodeIco(packed.bytes, frame: 0)!;
      expect(frame.getPixel(128, 128).a, 0);
    });

    test('非正方形：等比 contain 居中，留白为透明', () {
      // 512×256 → 缩放系数 0.5，内容 256×128，上下各留 64px 透明
      final packed = packIco(_rgba(512, 256), [256])!;
      final frame = img.decodeIco(packed.bytes, frame: 0)!;
      expect(frame.width, 256);
      expect(frame.height, 256);
      expect(frame.getPixel(128, 128).a, 255);
      expect(frame.getPixel(128, 10).a, 0);
      expect(frame.getPixel(128, 250).a, 0);
    });

    test('不透明源打包后 alpha 全为 255，不引入半透明', () {
      final rgb = img.Image(width: 64, height: 64, numChannels: 3);
      img.fill(rgb, color: img.ColorRgb8(10, 20, 30));
      final packed = packIco(rgb, [32])!;
      final frame = img.decodeIco(packed.bytes, frame: 0)!;
      expect(frame.getPixel(16, 16).a, 255);
    });

    test('索引色源（调色板图）可正常打包', () {
      final indexed = img.quantize(_rgba(64, 64), numberOfColors: 8);
      expect(indexed.hasPalette, isTrue);
      final packed = packIco(indexed, [16, 32])!;
      expect(packed.sizes, [16, 32]);
      expect(img.decodeIco(packed.bytes, frame: 1)!.width, 32);
    });
  });
}
