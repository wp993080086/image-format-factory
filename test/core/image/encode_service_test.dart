import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:pixel_forge/core/image/crop_selection.dart';
import 'package:pixel_forge/core/image/encode_service.dart';
import 'package:pixel_forge/core/image/ico_packer.dart';
import 'package:pixel_forge/core/image/image_format.dart';
import 'package:pixel_forge/core/image/resize_geometry.dart';

/// 渐变图：重复度高，deflate 的压缩级别差异能体现出来。
Uint8List _gradientPng({int size = 128}) {
  final image = img.Image(width: size, height: size, numChannels: 3);
  for (var y = 0; y < size; y++) {
    for (var x = 0; x < size; x++) {
      image.setPixelRgb(x, y, (x * 2) % 256, (y * 2) % 256, 128);
    }
  }
  return img.encodePng(image);
}

/// 伪随机噪声图：真彩 PNG 体积显著大于 256 色版本，便于比较压缩效果。
Uint8List _noisePng({int size = 64}) {
  final random = math.Random(42);
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

/// 生成带全透明像素的 RGBA PNG（用于验证透明填底）。
Uint8List _transparentPng(int w, int h) {
  final image = img.Image(width: w, height: h, numChannels: 4);
  img.fill(image, color: img.ColorRgba8(255, 0, 0, 0));
  return img.encodePng(image);
}

/// 100×80，左半红、右半蓝，用于验证裁剪确实取到了对应区域。
Uint8List _halves() {
  final image = img.Image(width: 100, height: 80, numChannels: 4);
  img.fill(image, color: img.ColorRgba8(0, 0, 255, 255));
  for (var y = 0; y < 80; y++) {
    for (var x = 0; x < 50; x++) {
      image.setPixelRgba(x, y, 255, 0, 0, 255);
    }
  }
  return img.encodePng(image);
}

/// 生成无 Alpha 通道的 JPEG（模拟照片类源文件）。
Uint8List _jpeg(int w, int h) {
  final image = img.Image(width: w, height: h, numChannels: 3);
  img.fill(image, color: img.ColorRgb8(120, 130, 140));
  return img.encodeJpg(image);
}

bool _startsWith(List<int> bytes, List<int> prefix) {
  if (bytes.length < prefix.length) return false;
  for (var i = 0; i < prefix.length; i++) {
    if (bytes[i] != prefix[i]) return false;
  }
  return true;
}

void main() {
  group('EncodeService', () {
    const service = EncodeService();

    test('PNG → PNG：保留原尺寸与透明通道', () async {
      final result = await service.encode(
        EncodeRequest(
          sourceBytes: _transparentPng(6, 5),
          format: ImageFormat.png,
        ),
      );
      expect(result, isNotNull);
      expect(_startsWith(result!.bytes, [0x89, 0x50, 0x4E, 0x47]), isTrue);
      expect(result.size.width, 6);
      expect(result.size.height, 5);
      expect(result.alphaFlattened, isFalse);

      final decoded = img.decodePng(result.bytes)!;
      expect(decoded.numChannels, 4);
    });

    test('透明 PNG → JPEG：填白底且不再含 Alpha 通道', () async {
      final result = await service.encode(
        EncodeRequest(
          sourceBytes: _transparentPng(6, 5),
          format: ImageFormat.jpeg,
          quality: 85,
        ),
      );
      expect(result, isNotNull);
      expect(_startsWith(result!.bytes, [0xFF, 0xD8, 0xFF]), isTrue);
      expect(result.size.width, 6);
      expect(result.size.height, 5);
      expect(result.alphaFlattened, isTrue);

      final decoded = img.decodeJpg(result.bytes)!;
      expect(decoded.numChannels, 3);
      // 全透明源 → 应被填成白底而非黑色
      final pixel = decoded.getPixel(0, 0);
      expect(pixel.r, greaterThan(240));
      expect(pixel.g, greaterThan(240));
      expect(pixel.b, greaterThan(240));
    });

    test('透明 PNG → BMP：填白底', () async {
      final result = await service.encode(
        EncodeRequest(
          sourceBytes: _transparentPng(4, 4),
          format: ImageFormat.bmp,
        ),
      );
      expect(result, isNotNull);
      expect(_startsWith(result!.bytes, [0x42, 0x4D]), isTrue);
      expect(result.alphaFlattened, isTrue);
    });

    test('无 Alpha 源 → JPEG：不做填底', () async {
      final result = await service.encode(
        EncodeRequest(sourceBytes: _jpeg(8, 8), format: ImageFormat.jpeg),
      );
      expect(result, isNotNull);
      expect(result!.alphaFlattened, isFalse);
      expect(result.size.width, 8);
    });

    test('质量参数生效：低质量体积更小', () async {
      final source = _transparentPng(64, 64);
      final high = await service.encode(
        EncodeRequest(
          sourceBytes: source,
          format: ImageFormat.jpeg,
          quality: 95,
        ),
      );
      final low = await service.encode(
        EncodeRequest(
          sourceBytes: source,
          format: ImageFormat.jpeg,
          quality: 20,
        ),
      );
      expect(low!.bytes.length, lessThan(high!.bytes.length));
    });

    test('透明 PNG → ICO：多尺寸打包且保留 alpha', () async {
      final result = await service.encode(
        EncodeRequest(
          sourceBytes: _transparentPng(256, 256),
          format: ImageFormat.ico,
          icoSizes: const [16, 32, 48],
        ),
      );
      expect(result, isNotNull);
      expect(result!.bytes.sublist(0, 4), [0, 0, 1, 0]);
      // 结果尺寸取打包中的最大项
      expect(result.size.width, 48);
      expect(result.alphaFlattened, isFalse);

      final ico = img.decodeIco(result.bytes)!;
      expect(ico.numFrames, 3);
      expect(ico.frames.map((f) => f.width), [16, 32, 48]);
      expect(ico.frames.first.getPixel(8, 8).a, 0);
    });

    test('ICO 未指定尺寸 → 取全部可生成尺寸，超原图的被剔除', () async {
      final result = await service.encode(
        EncodeRequest(
          sourceBytes: _transparentPng(64, 64),
          format: ImageFormat.ico,
        ),
      );
      expect(result, isNotNull);
      expect(img.decodeIco(result!.bytes)!.numFrames, 4); // 16/32/48/64
    });

    test('多尺寸 ICO → PNG：取最大尺寸帧，而非目录首项', () async {
      final source = img.Image(width: 256, height: 256, numChannels: 4);
      img.fill(source, color: img.ColorRgba8(10, 120, 200, 255));
      final ico = packIco(source, [16, 256])!.bytes;

      final result = await service.encode(
        EncodeRequest(sourceBytes: ico, format: ImageFormat.png),
      );
      expect(result, isNotNull);
      expect(result!.size.width, 256);
      expect(result.size.height, 256);
    });

    test('ICO 源重新打包 ICO：可用尺寸随最大帧恢复', () async {
      final source = img.Image(width: 256, height: 256, numChannels: 4);
      img.fill(source, color: img.ColorRgba8(10, 120, 200, 255));
      final ico = packIco(source, [16, 256])!.bytes;

      final result = await service.encode(
        EncodeRequest(sourceBytes: ico, format: ImageFormat.ico),
      );
      // 未修复时最大帧为 16 → 只有 16 一个尺寸可选
      expect(img.decodeIco(result!.bytes)!.numFrames, 6);
    });

    test('非图片字节 → 返回 null', () async {
      final result = await service.encode(
        EncodeRequest(
          sourceBytes: Uint8List.fromList([1, 2, 3, 4]),
          format: ImageFormat.png,
        ),
      );
      expect(result, isNull);
    });

    test('不可导出的格式 → 返回 null', () async {
      final result = await service.encode(
        EncodeRequest(
          sourceBytes: _transparentPng(4, 4),
          format: ImageFormat.webp,
        ),
      );
      expect(result, isNull);
    });
  });

  group('裁剪与编码一次完成（PRD 二章注）', () {
    const service = EncodeService();

    test('未传裁剪区时输出原尺寸', () async {
      final result = await service.encode(
        EncodeRequest(sourceBytes: _halves(), format: ImageFormat.png),
      );
      expect(result!.size.width, 100);
      expect(result.size.height, 80);
    });

    test('裁剪后输出尺寸等于选区尺寸', () async {
      final result = await service.encode(
        EncodeRequest(
          sourceBytes: _halves(),
          format: ImageFormat.png,
          crop: const CropArea(x: 10, y: 10, width: 40, height: 30),
        ),
      );
      expect(result!.size.width, 40);
      expect(result.size.height, 30);
    });

    test('裁剪确实取到了目标的像素区域', () async {
      // 左半区裁一块 → 应全为红色
      final result = await service.encode(
        EncodeRequest(
          sourceBytes: _halves(),
          format: ImageFormat.png,
          crop: const CropArea(x: 0, y: 0, width: 40, height: 40),
        ),
      );
      final decoded = img.decodePng(result!.bytes)!;
      final pixel = decoded.getPixel(20, 20);
      expect(pixel.r, 255);
      expect(pixel.b, 0);
    });

    test('圆形裁剪 → PNG 四角透明、中心不透明', () async {
      final result = await service.encode(
        EncodeRequest(
          sourceBytes: _halves(),
          format: ImageFormat.png,
          crop: const CropArea(x: 0, y: 0, width: 80, height: 80),
          cropCircle: true,
        ),
      );
      final decoded = img.decodePng(result!.bytes)!;
      expect(decoded.width, 80);
      expect(decoded.getPixel(40, 40).a, 255);
      expect(decoded.getPixel(0, 0).a, 0);
      expect(decoded.getPixel(79, 79).a, 0);
    });

    test('圆形裁剪 → JPEG：圆外透明被填成白底', () async {
      final result = await service.encode(
        EncodeRequest(
          sourceBytes: _halves(),
          format: ImageFormat.jpeg,
          crop: const CropArea(x: 0, y: 0, width: 80, height: 80),
          cropCircle: true,
        ),
      );
      expect(result!.alphaFlattened, isTrue);
      final decoded = img.decodeJpg(result.bytes)!;
      final corner = decoded.getPixel(0, 0);
      expect(corner.r, greaterThan(240));
      expect(corner.g, greaterThan(240));
      expect(corner.b, greaterThan(240));
    });

    test('裁剪后转 ICO：尺寸矩阵按裁剪后的新尺寸重算', () async {
      final result = await service.encode(
        EncodeRequest(
          sourceBytes: _halves(),
          format: ImageFormat.ico,
          crop: const CropArea(x: 0, y: 0, width: 64, height: 64),
        ),
      );
      // 裁剪后 64×64 → 可用尺寸 16/32/48/64，而非按原图 100 算出的更多项
      expect(img.decodeIco(result!.bytes)!.numFrames, 4);
    });

    test('空裁剪区被忽略，按原图输出', () async {
      final result = await service.encode(
        EncodeRequest(
          sourceBytes: _halves(),
          format: ImageFormat.png,
          crop: const CropArea(x: 0, y: 0, width: 0, height: 0),
        ),
      );
      expect(result!.size.width, 100);
      expect(result.size.height, 80);
    });

    test('带 resize 的请求按目标尺寸输出', () async {
      final result = await service.encode(
        EncodeRequest(
          sourceBytes: _halves(),
          format: ImageFormat.png,
          resize: const ResizeTarget(width: 25, height: 20),
        ),
      );
      expect(result!.size.width, 25);
      expect(result.size.height, 20);
      expect(img.decodePng(result.bytes)!.width, 25);
    });

    test('先裁后缩：裁剪作用于原图坐标，缩放作用于裁剪结果', () async {
      // 源 100×80 左红右蓝；裁左半（0..49）后缩到 20×16，结果应全红。
      // 若顺序反了（先缩后裁），裁到的会包含右半的蓝色。
      final result = await service.encode(
        EncodeRequest(
          sourceBytes: _halves(),
          format: ImageFormat.png,
          crop: const CropArea(x: 0, y: 0, width: 50, height: 60),
          resize: const ResizeTarget(width: 20, height: 16),
        ),
      );
      final decoded = img.decodePng(result!.bytes)!;
      expect(decoded.width, 20);
      expect(decoded.height, 16);
      final center = decoded.getPixel(10, 8);
      expect(center.r, greaterThan(200));
      expect(center.b, lessThan(60));
    });

    test('resize 与 JPEG 质量同一次编码生效', () async {
      final result = await service.encode(
        EncodeRequest(
          sourceBytes: _halves(),
          format: ImageFormat.jpeg,
          quality: 50,
          resize: const ResizeTarget(width: 40, height: 32),
        ),
      );
      final decoded = img.decodeJpg(result!.bytes)!;
      expect(decoded.width, 40);
      expect(decoded.height, 32);
    });
  });

  group('导出参数（PRD 五.1 / 五.2）', () {
    const service = EncodeService();

    test('4:4:4 体积大于 4:2:0', () async {
      final source = _noisePng();
      final chroma420 = await service.encode(
        EncodeRequest(
          sourceBytes: source,
          format: ImageFormat.jpeg,
          quality: 85,
          jpegChroma: JpegChromaOption.yuv420,
        ),
      );
      final chroma444 = await service.encode(
        EncodeRequest(
          sourceBytes: source,
          format: ImageFormat.jpeg,
          quality: 85,
          jpegChroma: JpegChromaOption.yuv444,
        ),
      );
      expect(chroma444!.bytes.length, greaterThan(chroma420!.bytes.length));
    });

    test('PNG 压缩级别越高体积越小', () async {
      final source = _gradientPng();
      final fast = await service.encode(
        EncodeRequest(
          sourceBytes: source,
          format: ImageFormat.png,
          pngLevel: 0,
        ),
      );
      final best = await service.encode(
        EncodeRequest(
          sourceBytes: source,
          format: ImageFormat.png,
          pngLevel: 9,
        ),
      );
      expect(best!.bytes.length, lessThan(fast!.bytes.length));
    });

    test('PNG 调色板压缩输出索引色且体积更小', () async {
      final source = _noisePng();
      final trueColor = await service.encode(
        EncodeRequest(sourceBytes: source, format: ImageFormat.png),
      );
      final paletted = await service.encode(
        EncodeRequest(
          sourceBytes: source,
          format: ImageFormat.png,
          pngPalette: true,
        ),
      );
      expect(img.decodePng(paletted!.bytes)!.hasPalette, isTrue);
      expect(img.decodePng(trueColor!.bytes)!.hasPalette, isFalse);
      expect(paletted.bytes.length, lessThan(trueColor.bytes.length));
    });

    test('半透明源即使传入 pngPalette 也自动跳过', () async {
      // 全图 alpha=128
      final image = img.Image(width: 32, height: 32, numChannels: 4);
      img.fill(image, color: img.ColorRgba8(200, 100, 50, 128));
      final result = await service.encode(
        EncodeRequest(
          sourceBytes: img.encodePng(image),
          format: ImageFormat.png,
          pngPalette: true,
        ),
      );
      expect(img.decodePng(result!.bytes)!.hasPalette, isFalse);
    });

    test('全透明源可以用调色板（透明不等于半透明）', () async {
      final image = img.Image(width: 32, height: 32, numChannels: 4);
      img.fill(image, color: img.ColorRgba8(0, 0, 0, 0));
      final result = await service.encode(
        EncodeRequest(
          sourceBytes: img.encodePng(image),
          format: ImageFormat.png,
          pngPalette: true,
        ),
      );
      expect(img.decodePng(result!.bytes)!.hasPalette, isTrue);
    });
  });

  group('整图模糊经编码管线生效（v0.6）', () {
    const service = EncodeService();

    test('blur=0 输出与不传一致', () async {
      final source = _halves();
      final plain = await service.encode(
        EncodeRequest(sourceBytes: source, format: ImageFormat.png),
      );
      final zero = await service.encode(
        EncodeRequest(sourceBytes: source, format: ImageFormat.png, blur: 0),
      );
      expect(zero!.bytes, plain!.bytes);
    });

    test('blur>0 把硬边界抹开（编码结果非原始红蓝）', () async {
      final result = await service.encode(
        EncodeRequest(sourceBytes: _halves(), format: ImageFormat.png, blur: 80),
      );
      final decoded = img.decodePng(result!.bytes)!;
      // 边界 x=49/50 原本是纯红/纯蓝，模糊后应出现过渡色
      final a = decoded.getPixel(49, 40);
      final b = decoded.getPixel(50, 40);
      final mixed = a.b > 10 || b.r > 10;
      expect(mixed, isTrue, reason: '边界应出现红蓝过渡，而非纯红纯蓝');
    });
  });
}
