import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// ICO 可选尺寸（PRD 一.4）。
///
/// 上限 256 不是自选值：`image` 的 `WinEncoder.encodeImages()` 对宽或高
/// 超过 256 直接抛异常，库本身无余量。
const List<int> icoSizeOptions = <int>[16, 32, 48, 64, 128, 256];

/// 某尺寸能否由 [width]×[height] 的原图生成（PRD 一.4「放大置灰」）。
///
/// ICO 输出为正方形、按 contain 适配（等比缩放 + 居中透明留白），缩放系数由
/// 较短边决定，因此只有 `目标尺寸 ≤ 较短边` 时才是缩小。超出即放大，禁止。
bool canRenderIcoSize(int size, {required int width, required int height}) {
  final shortEdge = math.min(width, height);
  return size > 0 && size <= 256 && size <= shortEdge;
}

/// 默认勾选的尺寸：全部可生成项（PRD 一.4「默认勾选全套」）。
List<int> defaultIcoSizes({required int width, required int height}) => [
  for (final size in icoSizeOptions)
    if (canRenderIcoSize(size, width: width, height: height)) size,
];

/// 逐尺寸重采样算法（PRD 一.4、三.3）：
/// `<64px` 用 `average`（近似 area 盒式滤波，小图标降采样更干净），
/// `≥64px` 用 `cubic`（`image` 包内质量最高的插值）。
///
/// PRD 原写「nearest + area / lanczos」，但该包只提供
/// nearest / linear / cubic / average 四种、无 lanczos；分档规则保留，
/// 档内改用包内等价最优算法（2026-11-11 确认）。
img.Interpolation interpolationForIcoSize(int size) =>
    size < 64 ? img.Interpolation.average : img.Interpolation.cubic;

/// ICO 打包结果。
class IcoPackResult {
  const IcoPackResult({required this.bytes, required this.sizes});

  final Uint8List bytes;

  /// 实际写入的尺寸，升序；已剔除放大与超上限项。
  final List<int> sizes;
}

/// 将已解码的全图打包为多尺寸 ICO：每尺寸独立重采样后内嵌 PNG（PRD 一.4）。
///
/// [sizes] 中不可生成的尺寸静默丢弃；全部无效时返回 null，由调用方转错误码。
IcoPackResult? packIco(img.Image source, Iterable<int> sizes) {
  final valid = <int>{
    for (final size in sizes)
      if (canRenderIcoSize(size, width: source.width, height: source.height))
        size,
  }.toList()..sort();
  if (valid.isEmpty) return null;

  // 索引色图无法参与 cubic/average 重采样（copyResize 会强制降为 nearest），
  // 故先展开为 RGBA；其余源保持原样，避免大图无谓地多占一份内存。
  final prepared = source.hasPalette ? source.convert(numChannels: 4) : source;

  return IcoPackResult(
    bytes: img.IcoEncoder().encodeImages([
      for (final size in valid) _renderIcon(prepared, size),
    ]),
    sizes: valid,
  );
}

/// 渲染单个图标：等比缩放到 [size]×[size] 画布，不足处留透明。
img.Image _renderIcon(img.Image source, int size) {
  final w = source.width;
  final h = source.height;
  if (w == size && h == size) return _toRgba(source);

  final scale = math.min(size / w, size / h);
  final targetW = math.max(1, (w * scale).round());
  final targetH = math.max(1, (h * scale).round());
  final resized = _toRgba(
    img.copyResize(
      source,
      width: targetW,
      height: targetH,
      interpolation: interpolationForIcoSize(size),
    ),
  );
  if (targetW == size && targetH == size) return resized;

  // 非正方形：居中合成到透明画布。用 direct 直写不做 alpha 混合，
  // 否则抗锯齿边缘会被与透明底再混合一次，alpha 被二次淡化。
  final canvas = img.Image(width: size, height: size, numChannels: 4);
  img.compositeImage(
    canvas,
    resized,
    center: true,
    blend: img.BlendMode.direct,
  );
  return canvas;
}

/// ICO 内嵌 PNG 统一 4 通道：任何源都能写出带 Alpha 的图标。
img.Image _toRgba(img.Image image) => image.hasPalette || image.numChannels != 4
    ? image.convert(numChannels: 4)
    : image;
