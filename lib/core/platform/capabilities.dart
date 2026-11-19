import '../image/image_format.dart';
import 'app_platform.dart';

/// 各端能力矩阵（对应 PRD「七、多端差异化策略」）。
///
/// 界面层据此对不支持的功能做隐藏/置灰，禁止在功能层内散落平台判断。
class PlatformCapabilities {
  const PlatformCapabilities({
    required this.target,
    required this.importFormats,
    required this.exportFormats,
    required this.dragDropImport,
    required this.pasteImport,
    required this.albumPickImport,
    required this.systemSavePanel,
    required this.animatedReencode,
    required this.maxPixels,
  });

  final AppTarget target;

  /// 【导入支持】格式集合。
  final Set<ImageFormat> importFormats;

  /// 【导出支持】格式集合。
  final Set<ImageFormat> exportFormats;

  /// 拖拽导入（仅 Windows）。
  final bool dragDropImport;

  /// 粘贴图片导入（仅 Web）。
  final bool pasteImport;

  /// 相册选择导入（微信小程序）。
  final bool albumPickImport;

  /// 唤起系统保存面板导出（Web 无此能力，走下载通道）。
  final bool systemSavePanel;

  /// 动图重编码（GIF/APNG 重新导出，高阶可选功能）。
  ///
  /// 全端 false：需求池 L-03 尚未实现，导入侧只取首帧，导出也只产静态图。
  /// 曾经三端标 true 但无任何代码引用——与 SVG 标 ✅ 是同一类不实能力位。
  final bool animatedReencode;

  /// 像素上限（PRD 九.3 表）：超过则拒绝，不做降级。
  ///
  /// 依据：Windows 100MP、Android/鸿蒙 32MP、Web 桌面 50MP、Web 移动 16MP。
  final int maxPixels;

  bool canImport(ImageFormat f) => importFormats.contains(f);

  bool canExport(ImageFormat f) => exportFormats.contains(f);

  /// 所有可导入格式的扩展名并集（供文件选择器过滤）。
  List<String> get importExtensions => [
    for (final f in importFormats) ...f.extensions,
  ];

  /// PRD 七章：按端给出能力矩阵。
  static PlatformCapabilities of(AppTarget target) => switch (target) {
    AppTarget.windows => PlatformCapabilities(
      target: target,
      // HEIC/HEIF 走 FFI 调随包分发的 libheif（Windows 不像 Android 有系统解码器）
      // v0.5/M3：加入 TIFF 双向、GIF 动图导出。AVIF 编解码库未随包分发前不开放
      // （能力位如实，见 AvifCodec.isSupportedFor），待 libavif.dll 就位再放开。
      importFormats: {..._mainstreamImport, ImageFormat.heic, ImageFormat.tiff},
      exportFormats: {
        ..._mainstreamExport,
        ImageFormat.ico,
        ImageFormat.webp,
        ImageFormat.tiff,
        ImageFormat.gif,
      },
      dragDropImport: true,
      pasteImport: false,
      albumPickImport: false,
      systemSavePanel: true,
      animatedReencode: false,
      maxPixels: 100 * 1000 * 1000,
    ),
    AppTarget.android => PlatformCapabilities(
      target: target,
      // HEIC/HEIF 走系统解码通道（Android 8.0+ 内置 HEVC 静态图解码），
      // 其余端解不了 HEVC，能力位不开——宁可选择器里看不到，也不让用户
      // 选到打不开的文件。
      importFormats: {..._mainstreamImport, ImageFormat.heic, ImageFormat.tiff},
      // WebP 走系统 Bitmap.compress(WEBP)，零新增依赖；TIFF/GIF 纯 Dart
      exportFormats: {
        ..._mainstreamExport,
        ImageFormat.ico,
        ImageFormat.webp,
        ImageFormat.tiff,
        ImageFormat.gif,
      },
      dragDropImport: false,
      pasteImport: false,
      albumPickImport: false,
      // 已落地：SAF ACTION_CREATE_DOCUMENT（ADR-007）
      systemSavePanel: true,
      animatedReencode: false,
      maxPixels: 32 * 1000 * 1000,
    ),
    AppTarget.harmony => PlatformCapabilities(
      target: target,
      importFormats: _mainstreamImport,
      exportFormats: {..._mainstreamExport, ImageFormat.ico},
      dragDropImport: false,
      pasteImport: false,
      albumPickImport: false,
      // 未落地：鸿蒙无 SAF 等价物，ADR-007 定的 share_plus 通道尚未接入（M3）。
      // 能力位如实写 false——不能重蹈 SVG 那次「三端标 ✅ 实际没有」的覆辙。
      systemSavePanel: false,
      animatedReencode: false,
      maxPixels: 32 * 1000 * 1000,
    ),
    AppTarget.web => PlatformCapabilities(
      target: target,
      importFormats: _mainstreamImport,
      exportFormats: _mainstreamExport,
      dragDropImport: false,
      pasteImport: true,
      albumPickImport: false,
      systemSavePanel: false,
      animatedReencode: false,
      // 取桌面浏览器上限；移动浏览器 16MP 需运行时判定（PRD 附录 #15 待实测）
      maxPixels: 50 * 1000 * 1000,
    ),
    AppTarget.wechatMini => PlatformCapabilities(
      target: target,
      importFormats: _mainstreamImport,
      exportFormats: _mainstreamExport,
      dragDropImport: false,
      pasteImport: false,
      albumPickImport: true,
      systemSavePanel: false,
      animatedReencode: false,
      maxPixels: 16 * 1000 * 1000,
    ),
  };

  /// 主流格式全集（非小众，PRD 一.边界3）。
  ///
  /// v0.5 / M3：TIFF 从需求池拉回（附录 #8 结论随优先级调整作废），
  /// `image` 包已内置 TIFF 解码器，纯 Dart 可读。`isNiche` 语义保留用于
  /// UI 排序，但能力位不再据此关闭。
  /// **不含 SVG**：没有光栅化能力——`image` 无 SVG 解码器，ADR-004 允许的
  /// `flutter_svg` + Engine 方案尚未接入。文件头能探测出 SVG 但解码不了，
  /// 放进来只会让选择器列出打不开的文件（S8 一致性检查项）。
  static const _mainstreamImport = {
    ImageFormat.jpeg,
    ImageFormat.png,
    ImageFormat.bmp,
    ImageFormat.webp,
    ImageFormat.gif,
    ImageFormat.apng,
    ImageFormat.ico,
  };

  /// 主流导出格式。
  ///
  /// 不含 WebP：`image` 包只提供 webp 解码器、无编码器，纯 Dart 路线不通
  /// （PRD 一 / 四.5 / 十，决策见 PRD 十二 ADR-001）。WebP 改为按端追加：
  /// Windows 走 FFI 调 libwebp，Android 走系统 Bitmap.compress(WEBP)。
  static const _mainstreamExport = {
    ImageFormat.jpeg,
    ImageFormat.png,
    ImageFormat.bmp,
  };
}
