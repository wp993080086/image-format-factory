import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:image_format_factory/core/image/encode_service.dart';
import 'package:image_format_factory/core/image/image_format.dart';
import 'package:image_format_factory/core/image/image_header_probe.dart';
import 'package:image_format_factory/core/image/resize_geometry.dart';

/// 伪随机噪声图：压缩率接近 1，便于检验外推倍数是否准确。
Uint8List _noisePng(int size) {
  final random = math.Random(7);
  final image = img.Image(width: size, height: size, numChannels: 3);
  for (var y = 0; y < size; y++) {
    for (var x = 0; x < size; x++) {
      image.setPixelRgb(
        x,
        y,
        random.nextInt(256),
        random.nextInt(256),
        random.nextInt(256),
      );
    }
  }
  return img.encodePng(image);
}

void main() {
  const service = EncodeService();

  group('EncodeService.estimate（PRD 四.7）', () {
    test('采样不外推时预估与实际编码体积一致', () async {
      final png = _noisePng(128);
      final actual = await service.encode(
        EncodeRequest(sourceBytes: png, format: ImageFormat.png),
      );
      final estimate = await service.estimate(
        EstimateRequest(
          previewPng: png,
          outputSize: const ImageDimensions(128, 128),
          format: ImageFormat.png,
        ),
      );

      expect(estimate, isNotNull);
      expect(
        estimate!,
        closeTo(actual!.bytes.length, actual.bytes.length * 0.05),
      );
    });

    test('输出像素 4 倍时按比例外推，误差小于 50%', () async {
      final png = _noisePng(256);
      final estimate = await service.estimate(
        EstimateRequest(
          previewPng: png,
          outputSize: const ImageDimensions(512, 512),
          format: ImageFormat.jpeg,
        ),
      );
      final actual = await service.encode(
        EncodeRequest(
          sourceBytes: png,
          format: ImageFormat.jpeg,
          resize: const ResizeTarget(width: 512, height: 512),
        ),
      );

      final error =
          (estimate! - actual!.bytes.length).abs() / actual.bytes.length;
      expect(error, lessThan(0.5));
    });

    test('ICO 不做预估，返回 null', () async {
      final estimate = await service.estimate(
        EstimateRequest(
          previewPng: _noisePng(64),
          outputSize: const ImageDimensions(64, 64),
          format: ImageFormat.ico,
        ),
      );
      expect(estimate, isNull);
    });

    test('非图片字节返回 null 而非抛异常', () async {
      final estimate = await service.estimate(
        EstimateRequest(
          previewPng: Uint8List.fromList([1, 2, 3, 4]),
          outputSize: const ImageDimensions(10, 10),
          format: ImageFormat.png,
        ),
      );
      expect(estimate, isNull);
    });

    test('质量越低预估体积越小', () async {
      final png = _noisePng(256);
      Future<int?> at(int quality) => service.estimate(
        EstimateRequest(
          previewPng: png,
          outputSize: const ImageDimensions(256, 256),
          format: ImageFormat.jpeg,
          quality: quality,
        ),
      );
      final low = await at(30);
      final high = await at(95);
      expect(low, lessThan(high!));
    });
  });
}
