import 'package:image/image.dart' as img;

/// 是否存在**半透明**像素（`0 < alpha < 255`）。
///
/// 用于 PRD 五.2：半透明源不能走 PNG 调色板压缩。PNG8 的调色板每个颜色只能
/// 带一个 alpha，同色不同 alpha 的像素会被合并，半透明边缘会退化成硬边。
///
/// 无 alpha 通道的源（JPEG / BMP）直接返回 false，不进入遍历。
/// 命中半透明像素即提前返回，只有「全不透明」或「全透明」的图需要扫完。
bool hasSemiTransparentPixels(img.Image image) {
  if (!image.hasAlpha) return false;
  final width = image.width;
  final height = image.height;
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final alpha = image.getPixel(x, y).a;
      if (alpha != 0 && alpha != 255) return true;
    }
  }
  return false;
}
