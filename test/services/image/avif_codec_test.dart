import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:pixel_forge/core/platform/app_platform.dart';
import 'package:pixel_forge/services/image/avif_cli.dart';
import 'package:pixel_forge/services/image/avif_codec.dart';

/// AVIF 随包 CLI 的真实编解码验证（仅 Windows）。
///
/// 直接调用 windows/native/bin/x64 里的 avifenc/avifdec，验证真实往返，
/// 不是 mock。CI/本机在 Windows 上才有意义。
void main() {
  const exeDir = 'windows/native/bin/x64';
  final enc = File('$exeDir/avifenc.exe');
  final dec = File('$exeDir/avifdec.exe');

  Uint8List gradient(int w, int h) {
    final rgba = Uint8List(w * h * 4);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final i = (y * w + x) * 4;
        rgba[i] = x * 4 % 256;
        rgba[i + 1] = y * 4 % 256;
        rgba[i + 2] = 128;
        rgba[i + 3] = 255;
      }
    }
    return rgba;
  }

  group('avifenc/avifdec 随包分发', () {
    test('两个 CLI 都在仓库里', () {
      expect(enc.existsSync(), isTrue, reason: enc.path);
      expect(dec.existsSync(), isTrue, reason: dec.path);
    });
  }, skip: !Platform.isWindows ? '仅 Windows 端随包分发 CLI' : null);

  group('AVIF CLI 真实编解码', () {
    test('RGBA 编码成 AVIF，文件头是 ftypavif', () async {
      final result = await encodeAvifCli(
        rgba: gradient(32, 32),
        width: 32,
        height: 32,
        quality: 60,
        exeDir: exeDir,
      );
      expect(result.isSuccess, isTrue, reason: result.error);
      final bytes = result.bytes!;
      expect(bytes.length, greaterThan(100));
      // ISO BMFF：偏移 4 起是 'ftyp'，随后 major brand 为 'avif'/'avis'
      expect(String.fromCharCodes(bytes.skip(4).take(4)), 'ftyp');
      final brand = String.fromCharCodes(bytes.skip(8).take(4));
      expect(brand == 'avif' || brand == 'avis', isTrue, reason: brand);
    });

    test('编码→解码往返，尺寸与颜色基本保持', () async {
      final encResult = await encodeAvifCli(
        rgba: gradient(32, 32),
        width: 32,
        height: 32,
        quality: 90,
        exeDir: exeDir,
      );
      expect(encResult.isSuccess, isTrue, reason: encResult.error);

      final decResult = await decodeAvifCli(
        encResult.bytes!,
        maxPixels: 1000000,
        exeDir: exeDir,
      );
      expect(decResult.isSuccess, isTrue, reason: decResult.error);
      final png = decResult.bytes!;
      expect(png.take(4), [0x89, 0x50, 0x4E, 0x47]);
      final image = img.decodePng(png);
      expect(image, isNotNull);
      expect(image!.width, 32);
      expect(image.height, 32);
      final pixel = image.getPixel(8, 8);
      expect(pixel.r, closeTo(32, 20));
      expect(pixel.g, closeTo(32, 20));
    });

    test('解码像素超限时失败', () async {
      final encResult = await encodeAvifCli(
        rgba: gradient(32, 32),
        width: 32,
        height: 32,
        quality: 60,
        exeDir: exeDir,
      );
      expect(encResult.isSuccess, isTrue);
      final decResult = await decodeAvifCli(
        encResult.bytes!,
        maxPixels: 10,
        exeDir: exeDir,
      );
      expect(decResult.isSuccess, isFalse);
    });

    test('非法 AVIF 数据解码失败而不崩溃', () async {
      final decResult = await decodeAvifCli(
        Uint8List.fromList(List<int>.filled(64, 7)),
        maxPixels: 1000000,
        exeDir: exeDir,
      );
      expect(decResult.isSuccess, isFalse);
    });
  }, skip: !Platform.isWindows ? 'AVIF CLI 仅 Windows 端可用' : null);

  group('AvifCodec 能力位', () {
    test('Windows 可编可解，Android 仅解码，其余不支持', () {
      expect(AvifCodec.isSupportedFor(AppTarget.windows), isTrue);
      expect(AvifCodec.isSupportedFor(AppTarget.android), isTrue);
      expect(AvifCodec.isSupportedFor(AppTarget.harmony), isFalse);
      expect(AvifCodec.isSupportedFor(AppTarget.web), isFalse);
      expect(AvifCodec.canEncodeFor(AppTarget.windows), isTrue);
      expect(AvifCodec.canEncodeFor(AppTarget.android), isFalse);
    });

    test('Windows 高层编码经 CLI 成功', () async {
      final result = await AvifCodec.encode(
        rgba: gradient(16, 16),
        width: 16,
        height: 16,
        quality: 70,
        target: AppTarget.windows,
        exeDir: exeDir,
      );
      expect(result.isSuccess, isTrue, reason: '${result.error}');
    });
  }, skip: !Platform.isWindows ? 'AVIF CLI 仅 Windows 端可用' : null);
}
