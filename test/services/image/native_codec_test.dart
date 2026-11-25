import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:image_format_factory/core/platform/app_platform.dart';
import 'package:image_format_factory/services/image/heif_decoder.dart';
import 'package:image_format_factory/services/image/webp_encoder.dart';

/// 随包分发的原生库（libwebp / libheif）的真实调用验证。
///
/// 这些用例直接加载 `windows/native/bin/x64` 里的 DLL，验证的是真实编解码
/// 行为，不是 mock。只在 Windows 上跑——DLL 是 Windows 构建产物。
void main() {
  final nativeDir = Directory('windows/native/bin/x64');
  final webpDll = '${nativeDir.path}/webp.dll';
  final heifDll = '${nativeDir.path}/heif.dll';
  final sharpyuvDll = '${nativeDir.path}/libsharpyuv.dll';
  final sampleHeic = File('test/fixtures/sample.heic');

  setUpAll(() {
    if (!Platform.isWindows) return;
    // libwebp.dll 依赖 libsharpyuv.dll：测试进程的可执行文件在 SDK 缓存里，
    // 按绝对路径加载 webp.dll 时依赖解析不到同目录的 sharpyuv，先手动加载
    if (File(sharpyuvDll).existsSync()) {
      DynamicLibrary.open(sharpyuvDll);
    }
  });

  group('原生库随包分发', () {
    test('三个 DLL 都在仓库里', () {
      expect(File(webpDll).existsSync(), isTrue, reason: webpDll);
      expect(File(heifDll).existsSync(), isTrue, reason: heifDll);
      // libwebp.dll 的有损编码依赖 libsharpyuv.dll，缺了会加载失败
      expect(File(sharpyuvDll).existsSync(), isTrue, reason: sharpyuvDll);
    });
  }, skip: !Platform.isWindows ? '仅 Windows 端随包分发原生库' : null);

  group('libwebp 真实编码', () {
    test('纯红 4×4 编码成 WebP，解回尺寸与颜色都对', () async {
      const width = 4;
      const height = 4;
      final rgba = Uint8List(width * height * 4);
      for (var i = 0; i < width * height; i++) {
        rgba[i * 4] = 255; // R
        rgba[i * 4 + 1] = 0; // G
        rgba[i * 4 + 2] = 0; // B
        rgba[i * 4 + 3] = 255; // A
      }

      final result = await WebpEncoder.encode(
        rgba: rgba,
        width: width,
        height: height,
        quality: 100,
        target: AppTarget.windows,
        libraryPath: webpDll,
      );

      expect(result.isSuccess, isTrue, reason: '编码应成功');
      final bytes = result.bytes!;
      // RIFF 容器：'RIFF' + 长度 + 'WEBP'
      expect(String.fromCharCodes(bytes.take(4)), 'RIFF');
      expect(String.fromCharCodes(bytes.skip(8).take(4)), 'WEBP');

      final decoded = img.decodeWebP(bytes);
      expect(decoded, isNotNull);
      expect(decoded!.width, width);
      expect(decoded.height, height);
      final pixel = decoded.getPixel(0, 0);
      expect(pixel.r, closeTo(255, 12));
      expect(pixel.g, closeTo(0, 12));
      expect(pixel.b, closeTo(0, 12));
      expect(pixel.a, closeTo(255, 12));
    });

    test('质量越低体积越小', () async {
      // 渐变图：高质量下细节多，低质量会被抹平
      const width = 64;
      const height = 64;
      final rgba = Uint8List(width * height * 4);
      for (var y = 0; y < height; y++) {
        for (var x = 0; x < width; x++) {
          final i = (y * width + x) * 4;
          rgba[i] = x * 4;
          rgba[i + 1] = y * 4;
          rgba[i + 2] = (x + y) * 2;
          rgba[i + 3] = 255;
        }
      }

      final high = await WebpEncoder.encode(
        rgba: rgba,
        width: width,
        height: height,
        quality: 95,
        target: AppTarget.windows,
        libraryPath: webpDll,
      );
      final low = await WebpEncoder.encode(
        rgba: rgba,
        width: width,
        height: height,
        quality: 20,
        target: AppTarget.windows,
        libraryPath: webpDll,
      );

      expect(high.isSuccess, isTrue);
      expect(low.isSuccess, isTrue);
      expect(low.bytes!.length, lessThan(high.bytes!.length));
    });
  }, skip: !Platform.isWindows ? 'libwebp 仅 Windows 端可用' : null);

  group('libheif 真实解码', () {
    test('sample.heic 解出 RGBA 像素', () async {
      final bytes = sampleHeic.readAsBytesSync();
      final result = await HeifDecoder.decode(
        bytes,
        maxPixels: 100 * 1000 * 1000,
        target: AppTarget.windows,
        libraryPath: heifDll,
      );

      expect(result.isSuccess, isTrue, reason: 'HEIC 应能解码');
      final png = result.png!;
      // 走的是「解码 → PNG 编码」这条路，产物必须是合法 PNG
      expect(png.take(4), [0x89, 0x50, 0x4E, 0x47]);
      final decoded = img.decodePng(png);
      expect(decoded, isNotNull);
      expect(decoded!.width, greaterThan(0));
      expect(decoded.height, greaterThan(0));
    });

    test('像素超限时在解码前就被拦下', () async {
      final bytes = sampleHeic.readAsBytesSync();
      final result = await HeifDecoder.decode(
        bytes,
        maxPixels: 1000,
        target: AppTarget.windows,
        libraryPath: heifDll,
      );

      expect(result.isSuccess, isFalse);
      expect(result.error, HeifDecodeError.pixelLimit);
    });

    test('非 HEIF 数据解码失败而不是崩溃', () async {
      final result = await HeifDecoder.decode(
        Uint8List.fromList(List.filled(64, 7)),
        maxPixels: 100 * 1000 * 1000,
        target: AppTarget.windows,
        libraryPath: heifDll,
      );

      expect(result.isSuccess, isFalse);
      expect(result.error, HeifDecodeError.failed);
    });
  }, skip: !Platform.isWindows ? 'libheif 仅 Windows 端可用' : null);
}
