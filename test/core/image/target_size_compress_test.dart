import 'package:flutter_test/flutter_test.dart';

import 'package:image_format_factory/core/image/target_size_compress.dart';

/// 模拟有损编码：体积随质量单调增（每质量 100 字节）。
Future<List<int>> _encoder(int quality) async => List<int>.filled(quality * 100, 1);

void main() {
  group('targetKbToBytes', () {
    test('按 1024 换算', () {
      expect(targetKbToBytes(1), 1024);
      expect(targetKbToBytes(0), 1024); // 下限保护
    });
  });

  group('compressToTargetSize', () {
    test('目标宽松时取最高质量', () async {
      final r = await compressToTargetSize(
        encode: _encoder,
        targetBytes: 20000,
      );
      expect(r, isNotNull);
      expect(r!.quality, 100);
      expect(r.hitTarget, isTrue);
    });

    test('目标很紧时取最低质量仍超限，hitTarget=false', () async {
      final r = await compressToTargetSize(
        encode: _encoder,
        targetBytes: 50,
      );
      expect(r!.quality, 1);
      expect(r.hitTarget, isFalse);
      expect(r.sizeBytes, 100);
    });

    test('中等目标收敛到满足目标的最高画质', () async {
      final r = await compressToTargetSize(
        encode: _encoder,
        targetBytes: 5000, // 质量 50 → 5000B
      );
      expect(r!.quality, 50);
      expect(r.hitTarget, isTrue);
      expect(r.sizeBytes, 5000);
    });

    test('返回体积确实不超过目标', () async {
      for (final target in [1000, 3500, 7800, 12000]) {
        final r = await compressToTargetSize(
          encode: _encoder,
          targetBytes: target,
        );
        expect(r!.sizeBytes, lessThanOrEqualTo(target));
      }
    });

    test('非法目标返回 null', () async {
      expect(
        await compressToTargetSize(encode: _encoder, targetBytes: 0),
        isNull,
      );
    });
  });
}
