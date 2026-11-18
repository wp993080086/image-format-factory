import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show RootIsolateToken;

import 'package:image/image.dart' as img;

import '../../services/image/webp_encoder.dart';
import 'alpha_scan.dart';
import 'crop_apply.dart';
import 'crop_selection.dart';
import 'format_detector.dart';
import 'ico_frame_select.dart';
import 'ico_packer.dart';
import 'image_format.dart';
import 'image_header_probe.dart';
import 'resize_apply.dart';
import 'resize_geometry.dart';

/// JPEG 色度抽样（PRD 五.1）。
///
/// `image` 包默认 `yuv444`，而 PRD 九.4 要求默认 4:2:0；两者体积差距可达
/// 20–30%，必须由调用方显式指定。
enum JpegChromaOption {
  yuv420('4:2:0', '体积更小，网页与照片常用'),
  yuv444('4:4:4', '保留更多色彩细节，体积更大');

  const JpegChromaOption(this.label, this.description);

  final String label;
  final String description;
}

/// 编码请求。
class EncodeRequest {
  const EncodeRequest({
    required this.sourceBytes,
    required this.format,
    this.quality = 85,
    this.icoSizes = const [],
    this.crop,
    this.cropCircle = false,
    this.resize,
    this.jpegChroma = JpegChromaOption.yuv420,
    this.pngLevel = 6,
    this.pngPalette = false,
  });

  /// 源文件字节流（会话期缓存，导出时据此二次解码全图，PRD 九.3 延迟渲染）。
  final Uint8List sourceBytes;

  /// 目标格式，须在 [EncodeService.exportableFormats] 内。
  final ImageFormat format;

  /// 质量 1–100，仅 JPEG 有意义（PRD 九.4 默认 85）。
  final int quality;

  /// ICO 打包尺寸，仅 [ImageFormat.ico] 有意义；为空时取全部可生成尺寸。
  final List<int> icoSizes;

  /// 裁剪区（原图像素坐标）；null 表示不裁剪。裁剪与编码在同一次解码内完成，
  /// 不产生中间文件（PRD 二章注 / 四章「一次编码」）。
  final CropArea? crop;

  /// 是否按圆形遮罩输出（PRD 二.7：方形画布 + 圆外透明）。
  final bool cropCircle;

  /// 尺寸与比例变换（PRD 三章）；null 表示保持原尺寸。
  ///
  /// 与 [crop] 一样在同一次解码内完成，先裁后缩，最后统一编码
  /// （PRD 五.6 一次编码原则）。
  final ResizeTarget? resize;

  /// JPEG 色度抽样，仅 [ImageFormat.jpeg] 有意义。
  final JpegChromaOption jpegChroma;

  /// PNG 压缩级别 0–9（0 不压缩、9 最高），仅 [ImageFormat.png] 有意义。
  final int pngLevel;

  /// 是否使用 PNG 调色板压缩（PNG8，有损，PRD 五.2）。
  ///
  /// 源图含半透明像素时编码端会自动跳过，见 [hasSemiTransparentPixels]。
  final bool pngPalette;
}

/// 编码结果。
class EncodeResult {
  const EncodeResult({
    required this.bytes,
    required this.size,
    required this.alphaFlattened,
  });

  final Uint8List bytes;

  /// 输出图像尺寸。
  final ImageDimensions size;

  /// 是否因目标格式不支持 Alpha 而做了透明填底（PRD 四.4 / 四.6），供 UI 提示。
  final bool alphaFlattened;
}

/// 体积预估请求（PRD 四.7）。
///
/// 输入是**预览图**而非原图字节：预览图长边已降到 2048，解码成本远低于
/// 原图；估算本来就不需要全分辨率内容。
class EstimateRequest {
  const EstimateRequest({
    required this.previewPng,
    required this.outputSize,
    required this.format,
    this.quality = 85,
    this.jpegChroma = JpegChromaOption.yuv420,
    this.pngLevel = 6,
    this.pngPalette = false,
  });

  final Uint8List previewPng;

  /// 最终输出的像素尺寸（已计入裁剪与缩放），用于把采样体积外推。
  final ImageDimensions outputSize;

  final ImageFormat format;
  final int quality;
  final JpegChromaOption jpegChroma;
  final int pngLevel;
  final bool pngPalette;
}

/// 图片编码服务：在独立 Isolate 中二次解码全图并编码为导出格式。
///
/// 对应 PRD 九.3 延迟渲染（导出时从源字节流重新解码）与八.9（编解码不占主 Isolate）。
class EncodeService {
  const EncodeService();

  /// 当前可导出的格式。
  ///
  /// WebP 走平台原生编码（Windows FFI / Android 系统编解码器），
  /// `image` 包本身没有编码器（ADR-001）。
  static const exportableFormats = <ImageFormat>[
    ImageFormat.jpeg,
    ImageFormat.png,
    ImageFormat.bmp,
    ImageFormat.webp,
    ImageFormat.ico,
  ];

  /// 编码 [EncodeRequest.sourceBytes] 为目标格式。
  ///
  /// 解码失败、格式不支持或 ICO 无可用尺寸时返回 null（由调用方转为
  /// `E-EXPORT-006`）。
  Future<EncodeResult?> encode(EncodeRequest request) {
    // 零拷贝传入子 Isolate（PRD 八.9）
    final transferable = TransferableTypedData.fromList([request.sourceBytes]);
    // Android 的 WebP 编码要在子 Isolate 里发起平台消息，得带上根 Isolate 令牌
    final token = _rootIsolateToken();
    return Isolate.run(
      () async => _encodeImage(
        transferable,
        request.format,
        request.quality,
        request.icoSizes,
        request.crop,
        request.cropCircle,
        request.resize,
        request.jpegChroma,
        request.pngLevel,
        request.pngPalette,
        token,
      ),
    );
  }

  /// 预估导出体积（PRD 四.7）。
  ///
  /// 把预览图降到长边 512 后按当前参数编码，再按「输出像素 / 采样像素」
  /// 外推。误差在 30% 量级以内，UI 以「约」呈现。
  ///
  /// ICO 是多尺寸打包，体积与单一像素数不构成比例关系，返回 null，
  /// 由 UI 隐藏预估（实际导出本身很快，无需预估）。
  Future<int?> estimate(EstimateRequest request) {
    final token = _rootIsolateToken();
    return Isolate.run(() async => _estimateBytes(request, token));
  }
}

/// 取根 Isolate 令牌；拿不到时返回 null（通道退回主 Isolate）。
RootIsolateToken? _rootIsolateToken() {
  try {
    return RootIsolateToken.instance;
  } catch (_) {
    return null;
  }
}

/// 子 Isolate 入口：解码全图 → 校正方向 → 裁剪 → 缩放 → 按需填底 → 编码。
///
/// 注意：此函数在独立 Isolate 中运行，禁止引用任何 UI / 插件对象。
Future<EncodeResult?> _encodeImage(
  TransferableTypedData transferable,
  ImageFormat format,
  int quality,
  List<int> icoSizes,
  CropArea? crop,
  bool cropCircle,
  ResizeTarget? resize,
  JpegChromaOption jpegChroma,
  int pngLevel,
  bool pngPalette,
  RootIsolateToken? token,
) async {
  final source = transferable.materialize().asUint8List();
  final decoded = img.decodeImage(source);
  if (decoded == null) return null;

  // ICO 是多尺寸容器，取像素数最大的那一帧（PRD 4.1）；其余格式保持原样
  final bitmap = ImageFormatDetector.isIco(source)
      ? largestIcoFrame(decoded)
      : decoded;

  // 方向在解码时烘焙，不写入导出（PRD 八.6，避免二次旋转）
  final oriented = img.bakeOrientation(bitmap);

  // 裁剪作用于原图全分辨率位图，先于所有导出处理（PRD 二章注：直接像素拷贝）
  var work = oriented;
  if (crop != null && !crop.isEmpty) {
    work = applyCrop(oriented, crop, circle: cropCircle);
  }
  // 缩放在裁剪之后：先按选区取内容，再把内容缩到目标尺寸。
  // 顺序反了会让「目标 200×150 + 裁剪」变成对缩放后的图再裁，坐标全错。
  if (resize != null) {
    work = applyResize(work, resize);
  }

  if (format == ImageFormat.ico) {
    // ICO 是多尺寸容器：每个尺寸独立重采样后打包为单文件（PRD 一.4）
    final packed = packIco(
      work,
      icoSizes.isEmpty
          ? defaultIcoSizes(width: work.width, height: work.height)
          : icoSizes,
    );
    if (packed == null) return null;
    final largest = packed.sizes.last;
    return EncodeResult(
      bytes: packed.bytes,
      size: ImageDimensions(largest, largest),
      alphaFlattened: false,
    );
  }

  var output = work;
  var alphaFlattened = false;
  if (!format.supportsAlpha && work.hasAlpha) {
    // 目标不支持 Alpha：透明区域填白底后合成（PRD 四.4 / 四.6）
    output = _flattenToWhite(work);
    alphaFlattened = true;
  }

  // WebP 没有纯 Dart 编码器，走平台原生能力（Windows FFI / Android 系统编解码器）
  if (format == ImageFormat.webp) {
    final result = await WebpEncoder.encode(
      rgba: output.getBytes(order: img.ChannelOrder.rgba),
      width: output.width,
      height: output.height,
      quality: quality.clamp(1, 100),
      token: token,
    );
    if (!result.isSuccess) return null;
    return EncodeResult(
      bytes: result.bytes!,
      size: ImageDimensions(output.width, output.height),
      alphaFlattened: false,
    );
  }

  final bytes = _encodeBytes(
    output,
    format,
    quality,
    jpegChroma,
    pngLevel,
    pngPalette,
  );
  if (bytes == null) return null;

  return EncodeResult(
    bytes: bytes,
    size: ImageDimensions(output.width, output.height),
    alphaFlattened: alphaFlattened,
  );
}

/// 透明区域填白底，返回 3 通道图（PRD 四.4 / 四.6）。
img.Image _flattenToWhite(img.Image image) {
  final background = img.Image(
    width: image.width,
    height: image.height,
    numChannels: 3,
  );
  img.fill(background, color: img.ColorRgb8(255, 255, 255));
  img.compositeImage(background, image);
  return background;
}

/// 按目标格式编码，导出与体积预估共用同一套参数。
Uint8List? _encodeBytes(
  img.Image image,
  ImageFormat format,
  int quality,
  JpegChromaOption jpegChroma,
  int pngLevel,
  bool pngPalette,
) {
  return switch (format) {
    // 注意：encodeJpg 默认色度抽样是 yuv444，PRD 九.4 要求默认 4:2:0，故显式传入
    ImageFormat.jpeg => img.encodeJpg(
      image,
      quality: quality.clamp(1, 100),
      chroma: jpegChroma == JpegChromaOption.yuv420
          ? img.JpegChroma.yuv420
          : img.JpegChroma.yuv444,
    ),
    ImageFormat.png => img.encodePng(
      _applyPalette(image, pngPalette),
      level: pngLevel.clamp(0, 9),
    ),
    ImageFormat.bmp => img.encodeBmp(image),
    _ => null,
  };
}

/// 子 Isolate 入口：估算体积（PRD 四.7）。
Future<int?> _estimateBytes(EstimateRequest request, RootIsolateToken? token) async {
  if (request.format == ImageFormat.ico) return null;
  final decoded = img.decodeImage(request.previewPng);
  if (decoded == null) return null;

  // 采样图：长边不超过 512。用 average 降采样，避免 cubic 在强缩小时
  // 引入额外细腻过渡而高估体积。
  const maxEdge = 512;
  final longEdge = math.max(decoded.width, decoded.height);
  final sample = longEdge <= maxEdge
      ? decoded
      : img.copyResize(
          decoded,
          width: math.max(1, (decoded.width * maxEdge / longEdge).round()),
          height: math.max(1, (decoded.height * maxEdge / longEdge).round()),
          interpolation: img.Interpolation.average,
        );

  final prepared = !request.format.supportsAlpha && sample.hasAlpha
      ? _flattenToWhite(sample)
      : sample;

  final int bytes;
  if (request.format == ImageFormat.webp) {
    final result = await WebpEncoder.encode(
      rgba: prepared.getBytes(order: img.ChannelOrder.rgba),
      width: prepared.width,
      height: prepared.height,
      quality: request.quality.clamp(1, 100),
      token: token,
    );
    if (!result.isSuccess) return null;
    bytes = result.bytes!.length;
  } else {
    final encoded = _encodeBytes(
      prepared,
      request.format,
      request.quality,
      request.jpegChroma,
      request.pngLevel,
      request.pngPalette,
    );
    if (encoded == null) return null;
    bytes = encoded.length;
  }

  final sampled = prepared.width * prepared.height;
  if (sampled <= 0) return null;
  final ratio = request.outputSize.pixels / sampled;
  return math.max(1, (bytes * ratio).round());
}

/// PNG8 调色板压缩（PRD 五.2）。
///
/// 半透明源自动跳过：PNG8 每个调色板项只能带一个 alpha，半透明边缘会在
/// 量化后退化成硬边，肉眼可见。UI 侧已禁用该选项，这里再兜一层，
/// 防止 API 被直接调用时静默劣化。
img.Image _applyPalette(img.Image image, bool palette) {
  if (!palette) return image;
  if (hasSemiTransparentPixels(image)) return image;
  return img.quantize(image, numberOfColors: 256);
}
