import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:pixel_forge/core/batch/batch_models.dart';
import 'package:pixel_forge/core/image/encode_service.dart';
import 'package:pixel_forge/core/image/image_format.dart';
import 'package:pixel_forge/core/platform/app_platform.dart';
import 'package:pixel_forge/services/batch/batch_pipeline.dart';
import 'package:pixel_forge/services/file/export_service.dart';

Uint8List _noisePng() {
  final image = img.Image(width: 128, height: 128, numChannels: 3);
  for (var y = 0; y < 128; y++) {
    for (var x = 0; x < 128; x++) {
      image.setPixelRgb(x, y, (x * 37 + y) % 256, (y * 53) % 256, (x * y) % 256);
    }
  }
  return img.encodePng(image);
}

void main() {
  group('BatchPipeline', () {
    test('编码 JPEG 产出合法 JPEG', () async {
      const pipeline = BatchPipeline(
        encodeService: EncodeService(),
        exportService: ExportService(target: AppTarget.windows),
      );
      final item = BatchItem(
        id: 0,
        fileName: 'a.png',
        sourceBytes: _noisePng(),
      );
      final encoded = await pipeline.encode(
        item,
        const BatchConfig(targetFormat: ImageFormat.jpeg, quality: 85),
      );
      expect(encoded, isNotNull);
      expect(encoded!.bytes[0], 0xFF);
      expect(encoded.bytes[1], 0xD8);
      expect(encoded.width, 128);
    });

    test('目标体积压缩使输出不超过目标（JPEG）', () async {
      const pipeline = BatchPipeline(
        encodeService: EncodeService(),
        exportService: ExportService(target: AppTarget.windows),
      );
      final item = BatchItem(
        id: 0,
        fileName: 'a.png',
        sourceBytes: _noisePng(),
      );
      const targetKb = 4;
      final encoded = await pipeline.encode(
        item,
        const BatchConfig(targetFormat: ImageFormat.jpeg, targetKb: targetKb),
      );
      expect(encoded, isNotNull);
      expect(encoded!.bytes.length, lessThanOrEqualTo(targetKb * 1024));
    });

    test('无损格式忽略目标体积设置', () async {
      const pipeline = BatchPipeline(
        encodeService: EncodeService(),
        exportService: ExportService(target: AppTarget.windows),
      );
      final item = BatchItem(id: 0, fileName: 'a.png', sourceBytes: _noisePng());
      final encoded = await pipeline.encode(
        item,
        const BatchConfig(targetFormat: ImageFormat.png, targetKb: 1),
      );
      // PNG 无损，质量二分不适用；仍能正常产出（可能超过 1KB）
      expect(encoded, isNotNull);
      expect(encoded!.bytes[1], 0x50); // PNG 'P'
    });
  });
}

