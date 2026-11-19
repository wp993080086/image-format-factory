import 'package:image/image.dart' as img;

/// 整图模糊（毛玻璃）强度上限，对应 UI 滑块 0–100。
const maxBlurIntensity = 100;

/// 把模糊强度换算成高斯半径（像素）。
///
/// 按图片短边缩放，让不同分辨率下的模糊观感一致：小图半径小、大图半径大。
/// 上限 80px 是性能与效果的折中——`image` 的高斯模糊代价随半径增长，
/// 再大在低端机的批量场景会明显拖慢导出。
///
/// [intensity] 为 0 时返回 0（调用方据此跳过模糊，零拷贝）。
int blurRadiusFor(int intensity, int shortEdge) {
  if (intensity <= 0) return 0;
  final clamped = intensity.clamp(0, maxBlurIntensity);
  final radius = (shortEdge * (clamped / maxBlurIntensity) * 0.04).round();
  return radius.clamp(1, 80);
}

/// 对整图做高斯模糊（毛玻璃），返回新图，不修改入参。
///
/// [intensity] 为 0 时原样返回入参对象（与调色/水印的 noop 语义一致，
/// 让编码管线省掉一次整图拷贝）。模糊发生在几何变换之后、其它编辑之前
/// 由编码服务统一编排；这里只负责像素处理。
img.Image applyGlobalBlur(img.Image source, int intensity) {
  final radius = blurRadiusFor(intensity, source.width < source.height
      ? source.width
      : source.height);
  if (radius == 0) return source;
  // gaussianBlur 会就地修改传入缓冲；先克隆，保证不破坏入参（调用方还要复用）。
  return img.gaussianBlur(img.Image.from(source), radius: radius);
}
