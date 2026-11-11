import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:pixel_forge/core/image/decode_service.dart';
import 'package:pixel_forge/core/image/ico_packer.dart';

/// 生成指定尺寸的真实 PNG 字节。
Uint8List _png(int w, int h) {
  final image = img.Image(width: w, height: h);
  return img.encodePng(image);
}

/// 生成两帧 GIF：第 1 帧红、第 2 帧蓝，用于验证不会被误换成最大帧逻辑。
Uint8List _twoFrameGif() {
  final first = img.Image(width: 8, height: 8, numChannels: 3);
  img.fill(first, color: img.ColorRgb8(255, 0, 0));
  final second = img.Image(width: 8, height: 8, numChannels: 3);
  img.fill(second, color: img.ColorRgb8(0, 0, 255));
  first.addFrame(second);
  return img.encodeGif(first);
}

void main() {
  group('DecodeService', () {
    const service = DecodeService();

    test('解码小图：预览图等于原图尺寸', () async {
      final result = await service.decodePreview(_png(100, 80));
      expect(result, isNotNull);
      expect(result!.sourceSize.width, 100);
      expect(result.sourceSize.height, 80);
      expect(result.previewSize.width, 100);
      expect(result.previewSize.height, 80);
      expect(result.previewPng, isNotEmpty);
    });

    test('大图触发降采样：预览长边为 2048，原图尺寸保留', () async {
      // 5000 × 1000：边长 5000 > 4096，触发降采样
      final result = await service.decodePreview(_png(5000, 1000));
      expect(result, isNotNull);
      expect(result!.sourceSize.width, 5000);
      expect(result.sourceSize.height, 1000);
      expect(result.previewSize.width, 2048);
      expect(result.previewSize.height, 410); // 1000 * 2048/5000 = 409.6 → 410
    });

    test('非图片字节 → 返回 null', () async {
      final result = await service.decodePreview(
        Uint8List.fromList([1, 2, 3, 4]),
      );
      expect(result, isNull);
    });

    test('多尺寸 ICO：按最大尺寸帧解码（PRD 4.1）', () async {
      final source = img.Image(width: 256, height: 256, numChannels: 4);
      img.fill(source, color: img.ColorRgba8(30, 120, 210, 255));
      final ico = packIco(source, [16, 32, 256])!.bytes;

      final result = await service.decodePreview(ico);
      expect(result, isNotNull);
      // 修复前这里是 16（库取目录首项）
      expect(result!.sourceSize.width, 256);
      expect(result.sourceSize.height, 256);
      expect(result.previewSize.width, 256);
    });

    test('动图 GIF 仍取第 1 帧，不受最大帧规则影响', () async {
      final result = await service.decodePreview(_twoFrameGif());
      expect(result, isNotNull);

      final preview = img.decodePng(result!.previewPng)!;
      // 两帧同尺寸，只能靠颜色区分；若被误换成最大帧会变成蓝色
      final pixel = preview.getPixel(4, 4);
      expect(pixel.r, greaterThan(200));
      expect(pixel.b, lessThan(60));
    });
  });
}
