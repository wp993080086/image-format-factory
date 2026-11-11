import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:pixel_forge/core/image/ico_frame_select.dart';
import 'package:pixel_forge/core/image/ico_packer.dart';

/// 构造多帧图：首个尺寸为主图，其余挂为 frames（模拟 ICO 目录顺序）。
img.Image _withFrames(List<int> sizes) {
  final first = img.Image(
    width: sizes.first,
    height: sizes.first,
    numChannels: 4,
  );
  for (final size in sizes.skip(1)) {
    first.addFrame(img.Image(width: size, height: size, numChannels: 4));
  }
  return first;
}

void main() {
  group('largestIcoFrame（PRD 4.1）', () {
    test('单帧：返回原对象本身，不拷贝', () {
      final single = _withFrames([64]);
      expect(identical(largestIcoFrame(single), single), isTrue);
    });

    test('目录升序：取最大帧，而非首项', () {
      final image = _withFrames([16, 32, 48, 256]);
      expect(largestIcoFrame(image).width, 256);
    });

    test('目录降序：最大帧即主图', () {
      final image = _withFrames([256, 128, 32, 16]);
      expect(largestIcoFrame(image).width, 256);
    });

    test('多帧同尺寸：保持首项，不改变既有行为', () {
      final image = _withFrames([32, 32, 32]);
      expect(identical(largestIcoFrame(image), image), isTrue);
    });

    test('真实打包的多尺寸 ICO：解码后取到 256', () {
      final source = img.Image(width: 256, height: 256, numChannels: 4);
      img.fill(source, color: img.ColorRgba8(200, 60, 60, 255));
      final ico = img.decodeImage(packIco(source, [16, 32, 256])!.bytes)!;

      expect(ico.width, 16); // 库的默认行为：主图取目录首项
      expect(largestIcoFrame(ico).width, 256);
    });
  });
}
