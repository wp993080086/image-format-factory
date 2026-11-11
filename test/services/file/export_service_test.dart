import 'package:flutter_test/flutter_test.dart';
import 'package:pixel_forge/core/image/image_format.dart';
import 'package:pixel_forge/services/file/export_service.dart';

void main() {
  group('buildExportFileName（PRD 九.4）', () {
    test('JPEG 以质量为标识，扩展名归一到 jpg', () {
      expect(
        buildExportFileName(
          sourceFileName: 'photo.jpeg',
          format: ImageFormat.jpeg,
          quality: 85,
          width: 1200,
          height: 800,
        ),
        'photo_q85.jpg',
      );
    });

    test('PNG / BMP 以尺寸为标识', () {
      expect(
        buildExportFileName(
          sourceFileName: 'shot.png',
          format: ImageFormat.png,
          quality: 85,
          width: 2400,
          height: 1600,
        ),
        'shot_2400x1600.png',
      );
      expect(
        buildExportFileName(
          sourceFileName: 'shot.png',
          format: ImageFormat.bmp,
          quality: 85,
          width: 64,
          height: 64,
        ),
        'shot_64x64.bmp',
      );
    });

    test('ICO 无单一宽高，标识固定为 icon', () {
      expect(
        buildExportFileName(
          sourceFileName: 'logo.png',
          format: ImageFormat.ico,
          quality: 85,
          width: 256,
          height: 256,
        ),
        'logo_icon.ico',
      );
    });

    test('文件名无扩展名时直接追加标识', () {
      expect(
        buildExportFileName(
          sourceFileName: 'noext',
          format: ImageFormat.png,
          quality: 85,
          width: 10,
          height: 10,
        ),
        'noext_10x10.png',
      );
    });

    test('文件名含多个点时只截断最后一段', () {
      expect(
        buildExportFileName(
          sourceFileName: 'a.b.c.png',
          format: ImageFormat.png,
          quality: 85,
          width: 1,
          height: 1,
        ),
        'a.b.c_1x1.png',
      );
    });
  });
}
