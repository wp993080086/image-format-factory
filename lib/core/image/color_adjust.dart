import 'package:image/image.dart' as img;

/// 基础调色参数（PRD 需求池二 / v0.5 M3）。
///
/// 所有数值为"增量语义"，0 表示不改变，便于 UI 用滑块从中间位置左右调节：
/// - [brightness]：亮度，-100~100，映射到乘性系数 1 + v/100
/// - [contrast]：对比度，-100~100，映射到 1 + v/100
/// - [saturation]：饱和度，-100~100，映射到 1 + v/100
/// - [hue]：色相偏移，度，-180~180
/// - [sharpen]：锐化强度，0~100
/// - [denoise]：降噪（高斯模糊半径 ×10），0~100
class ColorAdjust {
  const ColorAdjust({
    this.brightness = 0,
    this.contrast = 0,
    this.saturation = 0,
    this.hue = 0,
    this.sharpen = 0,
    this.denoise = 0,
  });

  final int brightness;
  final int contrast;
  final int saturation;
  final int hue;
  final int sharpen;
  final int denoise;

  bool get isNoop =>
      brightness == 0 &&
      contrast == 0 &&
      saturation == 0 &&
      hue == 0 &&
      sharpen == 0 &&
      denoise == 0;

  ColorAdjust copyWith({
    int? brightness,
    int? contrast,
    int? saturation,
    int? hue,
    int? sharpen,
    int? denoise,
  }) {
    return ColorAdjust(
      brightness: brightness ?? this.brightness,
      contrast: contrast ?? this.contrast,
      saturation: saturation ?? this.saturation,
      hue: hue ?? this.hue,
      sharpen: sharpen ?? this.sharpen,
      denoise: denoise ?? this.denoise,
    );
  }
}

/// 把基础调色应用到位图，返回新图（不修改入参）。
///
/// 处理顺序：降噪 → 锐化 → 亮度/对比度/饱和度/色相。
/// 先去噪再锐化，避免把噪声锐化成颗粒；调色放最后，作用在干净的亮度上。
img.Image applyColorAdjust(img.Image source, ColorAdjust p) {
  if (p.isNoop) return source;
  // adjustColor/convolution 都是原地修改，先克隆保证入参不变（调用方还要复用源图）。
  var work = img.Image.from(source);

  if (p.denoise > 0) {
    final radius = (p.denoise / 40).round().clamp(1, 5);
    work = img.gaussianBlur(work, radius: radius);
  }

  if (p.sharpen > 0) {
    // 锐化 = 原图 + strength × (原图 - 模糊图)，用拉普拉斯卷积核近似。
    final strength = (p.sharpen / 100.0).clamp(0.0, 1.0);
    const sharpenKernel = <num>[
      0, -1, 0,
      -1, 5, -1,
      0, -1, 0,
    ];
    work = img.convolution(work, filter: sharpenKernel, amount: strength);
  }

  work = img.adjustColor(
    work,
    brightness: 1 + p.brightness / 100.0,
    contrast: 1 + p.contrast / 100.0,
    saturation: 1 + p.saturation / 100.0,
    hue: p.hue.toDouble(),
  );

  return work;
}
