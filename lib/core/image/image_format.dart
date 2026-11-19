/// 支持的图片格式（对应 PRD「一、支持图片格式」）。
enum ImageFormat {
  jpeg,
  png,
  bmp,
  webp,
  tiff,
  tga,
  ppm,
  gif,
  apng,
  svg,
  ico,

  /// HEIF 容器 + HEVC 编码：苹果 HEIC、华为 HEIF 都是它。
  ///
  /// 纯 Dart 无 HEVC 解码器，解码依赖平台能力（Android 8.0+ 系统内置）。
  heic,

  /// AVIF 容器（AV1 编码，v0.5 起 M3 目标双向格式）。
  ///
  /// 纯 Dart 无 AV1 编解码器，导入/导出都借平台原生能力
  /// （Windows 随包 libavif FFI / Android 系统 ImageDecoder），
  /// 与 HEIC / WebP 同属纯 Dart 铁律例外。见 services/image/avif_codec.dart。
  avif;

  static ImageFormat? fromExtension(String ext) {
    final e = ext.toLowerCase().replaceAll('.', '');
    for (final f in ImageFormat.values) {
      if (f.extensions.contains(e)) return f;
    }
    return null;
  }
}

extension ImageFormatInfo on ImageFormat {
  String get displayName => switch (this) {
    ImageFormat.jpeg => 'JPEG',
    ImageFormat.png => 'PNG',
    ImageFormat.bmp => 'BMP',
    ImageFormat.webp => 'WebP',
    ImageFormat.tiff => 'TIFF',
    ImageFormat.tga => 'TGA',
    ImageFormat.ppm => 'PPM',
    ImageFormat.gif => 'GIF',
    ImageFormat.apng => 'APNG',
    ImageFormat.svg => 'SVG',
    ImageFormat.ico => 'ICO',
    ImageFormat.heic => 'HEIC',
    ImageFormat.avif => 'AVIF',
  };

  /// 扩展名集合。
  ///
  /// APNG 刻意返回空：它与 PNG 同为 `.png`，无法靠扩展名区分。若在此返回
  /// `['png']`，[ImageFormat.fromExtension] 会按枚举顺序先命中 png，
  /// 导致 apng 分支永远不可达、动图被当静态图静默丢帧（PRD 一.5）。
  /// APNG 必须通过文件头 `acTL` chunk 探测。
  List<String> get extensions => switch (this) {
    ImageFormat.jpeg => ['jpg', 'jpeg'],
    ImageFormat.png => ['png'],
    ImageFormat.bmp => ['bmp'],
    ImageFormat.webp => ['webp'],
    ImageFormat.tiff => ['tif', 'tiff'],
    ImageFormat.tga => ['tga'],
    ImageFormat.ppm => ['ppm'],
    ImageFormat.gif => ['gif'],
    ImageFormat.apng => const [],
    ImageFormat.svg => ['svg'],
    ImageFormat.ico => ['ico'],
    ImageFormat.heic => ['heic', 'heif'],
    ImageFormat.avif => ['avif'],
  };

  /// MIME 类型。
  ///
  /// Android 的 SAF（`ACTION_CREATE_DOCUMENT`）只认 MIME，不认扩展名，
  /// 导出时用它填 `mimeTypesFilter`（ADR-007）。
  /// APNG 与 PNG 同为 `image/png`：容器层看不出差别，也不需要看出。
  String get mimeType => switch (this) {
    ImageFormat.jpeg => 'image/jpeg',
    ImageFormat.png || ImageFormat.apng => 'image/png',
    ImageFormat.bmp => 'image/bmp',
    ImageFormat.webp => 'image/webp',
    ImageFormat.tiff => 'image/tiff',
    ImageFormat.tga => 'image/x-tga',
    ImageFormat.ppm => 'image/x-portable-pixmap',
    ImageFormat.gif => 'image/gif',
    ImageFormat.svg => 'image/svg+xml',
    ImageFormat.ico => 'image/x-icon',
    ImageFormat.heic => 'image/heic',
    ImageFormat.avif => 'image/avif',
  };

  /// 目标格式是否支持 Alpha 通道（对应 PRD「八.2 透明通道一致性」）。
  bool get supportsAlpha => switch (this) {
    ImageFormat.jpeg => false,
    ImageFormat.bmp => false,
    ImageFormat.tga => false,
    ImageFormat.ppm => false,
    _ => true,
  };

  bool get isAnimated => this == ImageFormat.gif || this == ImageFormat.apng;

  bool get isVector => this == ImageFormat.svg;

  bool get isContainer => this == ImageFormat.ico;

  /// 是否为 HEIF 家族容器（HEIC / AVIF）。
  ///
  /// 二者共用 ISO BMFF 外壳，解码却要分别走 HEVC 与 AV1，不能一把梭。
  bool get isHeifFamily => this == ImageFormat.heic || this == ImageFormat.avif;

  /// 小众格式：部分端天然缺少解码能力（PRD 一.边界3）。
  bool get isNiche =>
      this == ImageFormat.tiff ||
      this == ImageFormat.tga ||
      this == ImageFormat.ppm;
}
