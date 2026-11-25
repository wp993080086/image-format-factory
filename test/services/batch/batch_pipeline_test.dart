import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:image_format_factory/core/batch/batch_executor.dart';
import 'package:image_format_factory/core/batch/batch_models.dart';
import 'package:image_format_factory/core/image/encode_service.dart';
import 'package:image_format_factory/core/image/image_format.dart';
import 'package:image_format_factory/core/platform/app_platform.dart';
import 'package:image_format_factory/services/batch/batch_pipeline.dart';
import 'package:image_format_factory/services/file/export_service.dart';

/// 记录批量保存调用的替身：目录通道与逐张通道分开计数。
class _FakeExportService extends ExportService {
  _FakeExportService({this.destination});

  final ExportDestination? destination;
  final List<String> directorySaves = [];
  int fallbackSaves = 0;

  @override
  Future<ExportDestination?> pickExportDirectory() async => destination;

  @override
  Future<ExportResult?> saveToDirectory({
    required ExportDestination destination,
    required String suggestedName,
    required Uint8List bytes,
    List<String> mimeTypes = const [],
  }) async {
    directorySaves.add(suggestedName);
    return ExportResult(savedPath: '/out/$suggestedName');
  }

  @override
  Future<ExportResult?> save(ExportRequest request) async {
    fallbackSaves++;
    return ExportResult(savedPath: '/fallback/${request.suggestedName}');
  }
}

Uint8List _noisePng() {
  final image = img.Image(width: 128, height: 128, numChannels: 3);
  for (var y = 0; y < 128; y++) {
    for (var x = 0; x < 128; x++) {
      image.setPixelRgb(
        x,
        y,
        (x * 37 + y) % 256,
        (y * 53) % 256,
        (x * y) % 256,
      );
    }
  }
  return img.encodePng(image);
}

void main() {
  group('BatchPipeline', () {
    test('编码 JPEG 产出合法 JPEG', () async {
      final pipeline = BatchPipeline(
        encodeService: const EncodeService(),
        exportService: const ExportService(target: AppTarget.windows),
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
      final pipeline = BatchPipeline(
        encodeService: const EncodeService(),
        exportService: const ExportService(target: AppTarget.windows),
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
      final pipeline = BatchPipeline(
        encodeService: const EncodeService(),
        exportService: const ExportService(target: AppTarget.windows),
      );
      final item = BatchItem(
        id: 0,
        fileName: 'a.png',
        sourceBytes: _noisePng(),
      );
      final encoded = await pipeline.encode(
        item,
        const BatchConfig(targetFormat: ImageFormat.png, targetKb: 1),
      );
      // PNG 无损，质量二分不适用；仍能正常产出（可能超过 1KB）
      expect(encoded, isNotNull);
      expect(encoded!.bytes[1], 0x50); // PNG 'P'
    });

    test('选一次目录后逐张写入，文件名带递增序号', () async {
      final fake = _FakeExportService(
        destination: ExportDestination.windows('/out'),
      );
      final pipeline = BatchPipeline(
        encodeService: const EncodeService(),
        exportService: fake,
      );
      await pipeline.prepareExport();

      const config = BatchConfig(targetFormat: ImageFormat.png);
      final item = BatchItem(
        id: 0,
        fileName: 'a.png',
        sourceBytes: _noisePng(),
      );
      final encoded = BatchEncoded(
        bytes: Uint8List.fromList([1, 2, 3]),
        width: 10,
        height: 10,
      );
      await pipeline.save(item, config, encoded);
      await pipeline.save(item, config, encoded);

      expect(fake.directorySaves, [
        '001_a_10x10.png',
        '002_a_10x10.png',
      ], reason: '同一目录内用序号避免同名覆盖');
      expect(fake.fallbackSaves, 0, reason: '已选目录时不再逐张弹保存框');
    });

    test('未选目录时回落到逐张保存', () async {
      final fake = _FakeExportService();
      final pipeline = BatchPipeline(
        encodeService: const EncodeService(),
        exportService: fake,
      );
      await pipeline.prepareExport();
      await pipeline.save(
        BatchItem(id: 0, fileName: 'a.png', sourceBytes: _noisePng()),
        const BatchConfig(targetFormat: ImageFormat.png),
        BatchEncoded(bytes: Uint8List.fromList([1]), width: 1, height: 1),
      );
      expect(fake.fallbackSaves, 1);
      expect(fake.directorySaves, isEmpty);
    });
  });
}
