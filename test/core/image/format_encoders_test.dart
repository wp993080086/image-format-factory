import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:image_format_factory/core/image/encode_service.dart';
import 'package:image_format_factory/core/image/format_encoders.dart';
import 'package:image_format_factory/core/image/image_format.dart';

/// 造一张有明确颜色分布的图，便于 round-trip 后比对像素。
Uint8List _png({int w = 24, int h = 16}) {
  final image = img.Image(width: w, height: h, numChannels: 4);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      image.setPixelRgba(x, y, (x * 10) % 256, (y * 15) % 256, 120, 255);
    }
  }
  return img.encodePng(image);
}

void main() {
  group('FormatEncoders TIFF', () {
    test('canEncode 覆盖 tiff/gif/bmp，不含 avif/webp/ico', () {
      expect(FormatEncoders.canEncode(ImageFormat.tiff), isTrue);
      expect(FormatEncoders.canEncode(ImageFormat.gif), isTrue);
      expect(FormatEncoders.canEncode(ImageFormat.bmp), isTrue);
      expect(FormatEncoders.canEncode(ImageFormat.avif), isFalse);
      expect(FormatEncoders.canEncode(ImageFormat.webp), isFalse);
      expect(FormatEncoders.canEncode(ImageFormat.ico), isFalse);
    });

    test('TIFF 编码后能被 image 包解回，尺寸与像素一致', () {
      final src = img.decodeImage(_png())!;
      final tiff = FormatEncoders.encodeTiff(src);
      // TIFF 魔数：小端 II(49 49) 或大端 MM(4D 4D) 都合法
      final littleEndian = tiff[0] == 0x49 && tiff[1] == 0x49;
      final bigEndian = tiff[0] == 0x4D && tiff[1] == 0x4D;
      expect(littleEndian || bigEndian, isTrue);

      final decoded = img.decodeImage(tiff)!;
      expect(decoded.width, src.width);
      expect(decoded.height, src.height);
      expect(decoded.getPixel(3, 2).r, closeTo(src.getPixel(3, 2).r, 6));
    });
  });

  group('GIF 动图导出', () {
    test('多帧按序编码，解回后帧数一致、每帧时长保留', () {
      final frames = <GifFrame>[];
      for (var i = 0; i < 3; i++) {
        final f = img.Image(width: 16, height: 16, numChannels: 4);
        img.fill(f, color: img.ColorRgba8(i * 80, 0, 0, 255));
        frames.add(GifFrame(image: f, durationCentiseconds: 10 + i * 5));
      }
      final bytes = FormatEncoders.encodeGif(
        frames.first.image,
        frames: frames,
        loopCount: 0,
      );
      // GIF 魔数
      expect(bytes[0], 0x47);
      expect(bytes[1], 0x49);
      expect(bytes[2], 0x46);

      final decoded = img.decodeImage(bytes)!;
      expect(decoded.numFrames, 3);
      // decode 回来的 frameDuration 单位是毫秒 = 厘秒 × 10
      expect(decoded.getFrame(0).frameDuration, 100);
      expect(decoded.getFrame(1).frameDuration, 150);
      expect(decoded.getFrame(2).frameDuration, 200);
    });

    test('frames 为空时导出静态单帧', () {
      final f = img.Image(width: 8, height: 8, numChannels: 4);
      img.fill(f, color: img.ColorRgba8(255, 0, 0, 255));
      final bytes = FormatEncoders.encodeGif(f);
      final decoded = img.decodeImage(bytes)!;
      expect(decoded.numFrames, 1);
    });
  });

  group('EncodeService 新格式接入', () {
    test('exportableFormats 含 tiff/gif/avif', () {
      expect(EncodeService.exportableFormats, contains(ImageFormat.tiff));
      expect(EncodeService.exportableFormats, contains(ImageFormat.gif));
      expect(EncodeService.exportableFormats, contains(ImageFormat.avif));
    });

    test('源文件编为 TIFF，再解码尺寸一致', () async {
      final result = await const EncodeService().encode(
        EncodeRequest(sourceBytes: _png(), format: ImageFormat.tiff),
      );
      expect(result, isNotNull);
      final decoded = img.decodeImage(result!.bytes)!;
      expect(decoded.width, 24);
      expect(decoded.height, 16);
      expect(result.size.width, 24);
    });

    test('静态 GIF 导出成功', () async {
      final result = await const EncodeService().encode(
        EncodeRequest(sourceBytes: _png(), format: ImageFormat.gif),
      );
      expect(result, isNotNull);
      expect(result!.bytes[0], 0x47); // GIF
    });

    test('AVIF 在无原生库时编码返回 null（不崩溃）', () async {
      final result = await const EncodeService().encode(
        EncodeRequest(sourceBytes: _png(), format: ImageFormat.avif),
      );
      expect(result, isNull);
    });
  });
}
