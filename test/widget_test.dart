import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixel_forge/app/app.dart';
import 'package:pixel_forge/app/app_info.dart';
import 'package:pixel_forge/core/di/providers.dart';
import 'package:pixel_forge/core/error/app_error.dart';
import 'package:pixel_forge/core/image/annotation.dart';
import 'package:pixel_forge/core/image/cjk_text.dart';
import 'package:pixel_forge/core/image/decode_service.dart';
import 'package:pixel_forge/core/image/encode_service.dart';
import 'package:pixel_forge/core/image/image_format.dart';
import 'package:pixel_forge/core/image/image_header_probe.dart';
import 'package:pixel_forge/core/platform/app_platform.dart';
import 'package:pixel_forge/core/platform/capabilities.dart';
import 'package:pixel_forge/features/editor/editor_controller.dart';
import 'package:pixel_forge/services/file/export_service.dart';
import 'package:pixel_forge/services/file/import_service.dart';

/// 导入/解码替身：返回一张 4×4 的假图，避免测试依赖真实文件选择器与解码。
class _FakeImportService extends ImportService {
  _FakeImportService({this.animated = false, this.format = ImageFormat.png})
    : super(PlatformCapabilities.of(AppTarget.windows));

  final bool animated;
  final ImageFormat format;

  @override
  Future<ImportResult?> pickImage() async => ImportResult(
    fileName: animated ? 'a.gif' : 'a.png',
    bytes: Uint8List.fromList([1, 2, 3]),
    format: format,
    isAnimated: animated,
    extensionMismatch: false,
  );
}

class _FakeDecodeService extends DecodeService {
  const _FakeDecodeService([
    this.size = const ImageDimensions(4, 4),
    this.hasSemiTransparent = false,
  ]);

  /// 伪造的原图尺寸，供 ICO 尺寸矩阵等依赖真实宽高的用例切换。
  final ImageDimensions size;

  /// 伪造的半透明标记，供 PNG 调色板禁用逻辑的用例切换。
  final bool hasSemiTransparent;

  @override
  Future<DecodeResult?> decodePreview(Uint8List bytes) async => DecodeResult(
    previewPng: _onePixelPng,
    sourceSize: size,
    previewSize: size,
    hasSemiTransparent: hasSemiTransparent,
  );
}

/// 编码替身：记录最后一次请求，供断言裁剪/缩放参数是否随导出链路带下去。
class _RecordingEncodeService extends EncodeService {
  EncodeRequest? lastRequest;

  @override
  Future<EncodeResult?> encode(EncodeRequest request) async {
    lastRequest = request;
    final resize = request.resize;
    return EncodeResult(
      bytes: _onePixelPng,
      size: resize == null
          ? const ImageDimensions(4, 4)
          : ImageDimensions(resize.width, resize.height),
      alphaFlattened: false,
    );
  }
}

/// 保存替身：不唤起系统弹窗，直接返回一个假路径，并记录保存过的文件名与内容。
class _FakeExportService extends ExportService {
  _FakeExportService();

  final List<String> savedNames = <String>[];

  /// 最近一次保存的文本内容（诊断日志用例断言用）。
  String savedContent = '';

  @override
  Future<ExportResult?> save(ExportRequest request) async {
    savedNames.add(request.suggestedName);
    return ExportResult(savedPath: 'C:/out/${request.suggestedName}');
  }

  @override
  Future<ExportResult?> saveAs({
    required String suggestedName,
    required Uint8List bytes,
    required List<String> extensions,
    required String label,
    List<String>? mimeTypes,
  }) async {
    savedNames.add(suggestedName);
    savedContent = utf8.decode(bytes);
    return ExportResult(savedPath: 'C:/out/$suggestedName');
  }
}

/// 诊断日志替身：真实实现要读磁盘日志目录，组件测试里没有 path_provider
/// 通道，直接调用会永久挂起。
Future<String> _stubDiagnostics({String header = ''}) async =>
    '$header\n===== 当前会话 =====\n（测试会话）';

/// 一张真实的 1×1 透明 PNG，供 `Image.memory` 正常解码（假字节会触发 codec 异常）。
final Uint8List _onePixelPng = Uint8List.fromList(const [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
  0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
  0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
  0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
  0x42, 0x60, 0x82,
]);

Future<void> _bootHome(
  WidgetTester tester, {
  ImageDimensions size = const ImageDimensions(4, 4),
  bool hasSemiTransparent = false,
  Size viewSize = const Size(1000, 1400),
  EncodeService? encodeService,
  ExportService? exportService,
  ImportService? importService,
}) async {
  // 裁剪页底部参数面板较高，默认 800×600 视口会把画布压到溢出
  tester.view.physicalSize = viewSize;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        importServiceProvider.overrideWithValue(
          importService ?? _FakeImportService(),
        ),
        decodeServiceProvider.overrideWithValue(
          _FakeDecodeService(size, hasSemiTransparent),
        ),
        exportServiceProvider.overrideWithValue(
          exportService ?? _FakeExportService(),
        ),
        diagnosticsProvider.overrideWithValue(_stubDiagnostics),
        if (encodeService != null)
          encodeServiceProvider.overrideWithValue(encodeService),
      ],
      child: const PixelForgeApp(),
    ),
  );
  await tester.pumpAndSettle();
}

/// 首页选图进入可编辑态，功能入口才可用（PRD 九.5）。
Future<void> _importImage(WidgetTester tester) async {
  await tester.tap(find.text('选择文件'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('首页渲染：标题与功能入口可见', (tester) async {
    await _bootHome(tester);

    expect(find.text('像素工坊'), findsOneWidget);
    expect(find.text('裁剪'), findsOneWidget);
    expect(find.text('尺寸与比例'), findsOneWidget);
    expect(find.text('格式转换'), findsOneWidget);
    expect(find.text('图片压缩'), findsOneWidget);
    expect(find.text('标注与打码'), findsOneWidget);
  });

  testWidgets('未导入图片时功能入口不可点击', (tester) async {
    await _bootHome(tester);

    // 未导入 → 入口置灰，点击不跳转，不会出现导出参数面板。
    await tester.tap(find.text('格式转换'));
    await tester.pumpAndSettle();
    expect(find.text('输出格式'), findsNothing);
  });

  testWidgets('格式转换入口进入导出参数面板', (tester) async {
    await _bootHome(tester);
    await _importImage(tester);

    await tester.tap(find.text('格式转换'));
    await tester.pumpAndSettle();

    expect(find.text('导出'), findsOneWidget);
    expect(find.text('输出格式'), findsOneWidget);
    // 源格式 PNG 可导出 → 默认跟随源格式（PRD 九.4）
    expect(find.widgetWithText(FilledButton, '导出 PNG'), findsOneWidget);
  });

  testWidgets('图片压缩入口进入同一导出面板', (tester) async {
    await _bootHome(tester);
    await _importImage(tester);

    await tester.tap(find.text('图片压缩'));
    await tester.pumpAndSettle();

    // 两个入口共用同一面板：参数同屏、一次编码（PRD 五.6）
    expect(find.text('输出格式'), findsOneWidget);
    expect(find.byType(TabBar), findsNothing);
  });

  testWidgets('导出面板：ICO 尺寸超过原图较短边的项置灰', (tester) async {
    await _bootHome(tester, size: const ImageDimensions(128, 128));
    await _importImage(tester);

    await tester.tap(find.text('格式转换'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('ICO'));
    await tester.pumpAndSettle();

    expect(find.text('图标尺寸'), findsOneWidget);
    // 128 边长可生成 16/32/48/64/128 共 5 项，256 超出原图 → 置灰
    final chip256 = tester.widget<FilterChip>(
      find.widgetWithText(FilterChip, '256'),
    );
    expect(chip256.onSelected, isNull);
    final chip128 = tester.widget<FilterChip>(
      find.widgetWithText(FilterChip, '128'),
    );
    expect(chip128.onSelected, isNotNull);
    expect(chip128.selected, isTrue);
    expect(find.widgetWithText(FilledButton, '导出 ICO（5 个尺寸）'), findsOneWidget);
  });

  testWidgets('导出面板：ICO 说明看图软件只显示一张是查看器行为', (tester) async {
    await _bootHome(tester, size: const ImageDimensions(128, 128));
    await _importImage(tester);

    await tester.tap(find.text('格式转换'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('ICO'));
    await tester.pumpAndSettle();

    // 多尺寸 ICO 常被误解为导出失败，UI 需明确说明
    expect(find.textContaining('看图软件打开 .ico 通常只显示其中一张'), findsOneWidget);
    expect(find.textContaining('文件内已写入 5 个尺寸'), findsOneWidget);
  });

  testWidgets('裁剪页：可编辑态展示预览图与原图尺寸', (tester) async {
    await _bootHome(tester);
    await _importImage(tester);

    await tester.tap(find.text('裁剪'));
    await tester.pumpAndSettle();

    expect(find.byType(Image), findsOneWidget);
    expect(find.textContaining('原图 4 × 4'), findsOneWidget);
  });

  testWidgets('裁剪页：默认全选整图，展示选区坐标与导出入口', (tester) async {
    await _bootHome(tester);
    await _importImage(tester);

    await tester.tap(find.text('裁剪'));
    await tester.pumpAndSettle();

    // 默认全选：面板右上角显示选区尺寸，下方显示原图坐标
    expect(find.text('4 × 4'), findsOneWidget);
    expect(find.textContaining('选区 x 0, y 0'), findsOneWidget);
    expect(find.text('下一步：导出'), findsOneWidget);
  });

  testWidgets('裁剪页：切到圆形后非 1:1 比例置灰', (tester) async {
    await _bootHome(tester);
    await _importImage(tester);

    await tester.tap(find.text('裁剪'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('圆形'));
    await tester.pumpAndSettle();

    // 圆形只允许自由与 1:1（PRD 二.2 合法性矩阵）
    final chip43 = tester.widget<ChoiceChip>(
      find.widgetWithText(ChoiceChip, '4:3'),
    );
    expect(chip43.onSelected, isNull);
    final chip11 = tester.widget<ChoiceChip>(
      find.widgetWithText(ChoiceChip, '1:1'),
    );
    expect(chip11.onSelected, isNotNull);
    expect(find.text('圆形选区输出方形画布，圆外填充透明'), findsOneWidget);
  });

  testWidgets('裁剪页：下一步进入导出面板，并提示已裁剪', (tester) async {
    await _bootHome(tester);
    await _importImage(tester);

    await tester.tap(find.text('裁剪'));
    await tester.pumpAndSettle();

    // 缩小选区后再进导出，导出面板应显式告知内容已被裁剪
    await tester.enterText(find.widgetWithText(TextField, '宽（px）'), '2');
    await tester.enterText(find.widgetWithText(TextField, '高（px）'), '2');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    await tester.tap(find.text('下一步：导出'));
    await tester.pumpAndSettle();

    expect(find.text('输出格式'), findsOneWidget);
    expect(find.textContaining('已裁剪'), findsOneWidget);
    expect(find.text('还原整图'), findsOneWidget);
  });

  testWidgets('导出面板：PNG 显示压缩级别与调色板开关', (tester) async {
    await _bootHome(tester);
    await _importImage(tester);

    await tester.tap(find.text('格式转换'));
    await tester.pumpAndSettle();

    // 源格式 PNG → 默认目标 PNG，直接显示 PNG 参数（PRD 五.2）
    expect(find.text('压缩级别'), findsOneWidget);
    final palette = tester.widget<SwitchListTile>(
      find.widgetWithText(SwitchListTile, '调色板压缩（PNG8）'),
    );
    expect(palette.onChanged, isNotNull);
    expect(find.textContaining('最多 256 色'), findsOneWidget);
    // 体积预估块（PRD 四.7）：首次进入即开始计算
    expect(find.text('预估体积'), findsOneWidget);
  });

  testWidgets('导出面板：半透明源禁用调色板压缩并说明原因', (tester) async {
    await _bootHome(tester, hasSemiTransparent: true);
    await _importImage(tester);

    await tester.tap(find.text('格式转换'));
    await tester.pumpAndSettle();

    final palette = tester.widget<SwitchListTile>(
      find.widgetWithText(SwitchListTile, '调色板压缩（PNG8）'),
    );
    expect(palette.onChanged, isNull);
    expect(find.textContaining('源图含半透明像素'), findsOneWidget);
  });

  testWidgets('导出面板：JPEG 显示色度抽样，默认 4:2:0', (tester) async {
    await _bootHome(tester);
    await _importImage(tester);

    await tester.tap(find.text('格式转换'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('JPEG'));
    await tester.pumpAndSettle();

    expect(find.text('色度抽样'), findsOneWidget);
    expect(find.text('4:2:0'), findsOneWidget);
    expect(find.text('4:4:4'), findsOneWidget);
    // 默认选中 4:2:0：其说明文案可见
    expect(find.textContaining('体积更小'), findsOneWidget);
  });

  testWidgets('导出面板：WebP 显示质量滑块，无色度抽样', (tester) async {
    await _bootHome(tester);
    await _importImage(tester);

    await tester.tap(find.text('格式转换'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('WebP'));
    await tester.pumpAndSettle();

    expect(find.text('质量'), findsOneWidget);
    expect(find.text('85'), findsOneWidget);
    expect(find.text('色度抽样'), findsNothing);
    expect(find.textContaining('WebP 质量参数与 JPEG 一致'), findsOneWidget);
  });

  testWidgets('尺寸页：展示原图与目标尺寸，默认不缩放', (tester) async {
    await _bootHome(tester, size: const ImageDimensions(400, 300));
    await _importImage(tester);

    await tester.tap(find.text('尺寸与比例'));
    await tester.pumpAndSettle();

    expect(find.textContaining('原图 400 × 300'), findsOneWidget);
    expect(find.textContaining('目标 400 × 300'), findsOneWidget);
    expect(find.text('下一步：导出'), findsOneWidget);
  });

  testWidgets('尺寸页：留白底色只在 contain 模式出现', (tester) async {
    await _bootHome(tester, size: const ImageDimensions(400, 300));
    await _importImage(tester);

    await tester.tap(find.text('尺寸与比例'));
    await tester.pumpAndSettle();

    // 默认拉伸填充：不产生留白，因此没有底色选项
    expect(find.text('透明'), findsNothing);

    await tester.tap(find.text('留白填充'));
    await tester.pumpAndSettle();

    expect(find.text('透明'), findsOneWidget);
    expect(find.text('白色'), findsOneWidget);
  });

  testWidgets('尺寸页：超过 4 倍放大被钳制并提示', (tester) async {
    await _bootHome(tester, size: const ImageDimensions(400, 300));
    await _importImage(tester);

    await tester.tap(find.text('尺寸与比例'));
    await tester.pumpAndSettle();

    // 400×300 的单边上限为 1600×1200
    await tester.enterText(find.widgetWithText(TextField, '宽（px）'), '2000');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(find.textContaining('已达单边放大上限'), findsOneWidget);
    expect(find.textContaining('目标 1600 × 1200'), findsOneWidget);
  });

  testWidgets('尺寸页：下一步进入导出面板并提示已调整', (tester) async {
    await _bootHome(tester, size: const ImageDimensions(400, 300));
    await _importImage(tester);

    await tester.tap(find.text('尺寸与比例'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, '宽（px）'), '200');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    await tester.tap(find.text('下一步：导出'));
    await tester.pumpAndSettle();

    expect(find.text('输出格式'), findsOneWidget);
    expect(find.textContaining('已调整为 200 × 150'), findsOneWidget);
    expect(find.text('还原原始尺寸'), findsOneWidget);
  });

  // ---------- S5 快捷键与无障碍（PRD 九.6） ----------

  testWidgets('快捷键：Ctrl+O 触发导入', (tester) async {
    await _bootHome(tester);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyO);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();

    // 导入成功后功能入口才可用：能进面板即说明导入已发生
    await tester.tap(find.text('格式转换'));
    await tester.pumpAndSettle();
    expect(find.text('输出格式'), findsOneWidget);
  });

  testWidgets('快捷键：Esc 返回上一页', (tester) async {
    await _bootHome(tester);
    await _importImage(tester);
    await tester.tap(find.text('格式转换'));
    await tester.pumpAndSettle();
    expect(find.text('输出格式'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(find.text('像素工坊'), findsOneWidget);
    expect(find.text('输出格式'), findsNothing);
  });

  testWidgets('快捷键：Ctrl+S 直接导出', (tester) async {
    final encode = _RecordingEncodeService();
    await _bootHome(tester, encodeService: encode);
    await _importImage(tester);
    await tester.tap(find.text('格式转换'));
    await tester.pumpAndSettle();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();

    expect(find.text('导出完成'), findsOneWidget);
    // 与导出按钮同一套参数：格式跟随源格式 PNG
    expect(encode.lastRequest?.format, ImageFormat.png);
  });

  testWidgets('裁剪页：方向键微调选区，Shift 步长为 10', (tester) async {
    await _bootHome(tester);
    await _importImage(tester);
    await tester.tap(find.text('裁剪'));
    await tester.pumpAndSettle();

    // 先缩到 2×2，默认居中于 (1,1)
    await tester.enterText(find.widgetWithText(TextField, '宽（px）'), '2');
    await tester.enterText(find.widgetWithText(TextField, '高（px）'), '2');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.textContaining('选区 x 1, y 1'), findsOneWidget);

    // 点画布把键盘焦点从输入框收回到画布
    await tester.tap(find.byKey(const ValueKey('cropCanvas')));
    await tester.pumpAndSettle();

    // Shift + 方向键：10px 步长，4×4 图内钳制到右边界 x = 4-2 = 2
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();
    expect(find.textContaining('选区 x 2, y 1'), findsOneWidget);

    // 单按方向键：1px 步长
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(find.textContaining('选区 x 2, y 2'), findsOneWidget);
  });

  testWidgets('裁剪页：画布提供无障碍选区描述', (tester) async {
    await _bootHome(tester);
    await _importImage(tester);
    await tester.tap(find.text('裁剪'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('cropCanvas')), findsOneWidget);
    expect(find.bySemanticsLabel('裁剪画布'), findsOneWidget);
  });

  // ---------- S6 关于页与诊断日志（PRD 十三、十六.2） ----------

  testWidgets('关于页：展示版本号与隐私说明', (tester) async {
    await _bootHome(tester);

    await tester.tap(find.byTooltip('关于'));
    await tester.pumpAndSettle();

    expect(find.text('版本 $appVersionLabel'), findsOneWidget);
    expect(find.text('隐私说明'), findsOneWidget);
    // 隐私声明是上架硬要求，逐条列出而不是一句话概括
    expect(find.textContaining('不上传任何图片'), findsOneWidget);
    expect(find.text('第三方组件许可'), findsOneWidget);
  });

  testWidgets('关于页：导出诊断日志走保存通道', (tester) async {
    final export = _FakeExportService();
    await _bootHome(tester, exportService: export);
    await tester.tap(find.byTooltip('关于'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('导出诊断日志'));
    await tester.pumpAndSettle();

    expect(export.savedNames.length, 1);
    expect(export.savedNames.single, startsWith('pixel-forge-log-'));
    expect(export.savedNames.single, endsWith('.txt'));
    expect(export.savedContent, contains('当前会话'));
    expect(find.textContaining('诊断日志已保存'), findsOneWidget);
  });

  // ---------- S8 全流程验收（PRD 十一、十五章） ----------

  testWidgets('全流程：导入 → 裁剪 → 改尺寸 → 导出，一次编码携带全部参数', (tester) async {
    final encode = _RecordingEncodeService();
    await _bootHome(
      tester,
      size: const ImageDimensions(800, 600),
      encodeService: encode,
    );
    await _importImage(tester);

    // 1) 裁剪到 400×300：以原图中心为锚点，落点 x=200 y=150
    await tester.tap(find.text('裁剪'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, '宽（px）'), '400');
    await tester.enterText(find.widgetWithText(TextField, '高（px）'), '300');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.textContaining('选区 x 200, y 150'), findsOneWidget);

    // 2) 回首页进尺寸页，改为 200×150（比例锁默认开启，宽度联动高度）
    // 中文界面下 pageBack() 找不到 'Back' 提示语，直接点 AppBar 返回键
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text('尺寸与比例'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, '宽（px）'), '200');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    // 3) 导出：裁剪 + 缩放必须在同一次编码请求内（PRD 五.6 一次编码）
    await tester.tap(find.text('下一步：导出'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('导出 PNG'));
    await tester.pumpAndSettle();

    expect(find.text('导出完成'), findsOneWidget);
    final request = encode.lastRequest!;
    expect(request.format, ImageFormat.png);
    expect(request.crop?.x, 200);
    expect(request.crop?.y, 150);
    expect(request.crop?.width, 400);
    expect(request.crop?.height, 300);
    expect(request.resize?.width, 200);
    expect(request.resize?.height, 150);
  });

  testWidgets('导入：能力矩阵之外的格式提示不支持而非文件损坏', (tester) async {
    await _bootHome(tester);

    // 拖拽路径可绕过选择器的扩展名过滤，SVG 能被探测但无光栅化能力
    final container = ProviderScope.containerOf(
      tester.element(find.byType(Scaffold).first),
    );
    await container
        .read(editorControllerProvider.notifier)
        .loadImport(
          ImportResult(
            fileName: 'a.svg',
            bytes: Uint8List.fromList(utf8.encode('<svg></svg>')),
            format: ImageFormat.svg,
            isAnimated: false,
            extensionMismatch: false,
          ),
        );
    await tester.pumpAndSettle();

    expect(
      find.textContaining(AppErrorCode.unsupportedFormat.code),
      findsOneWidget,
    );
    expect(find.textContaining(AppErrorCode.corruptedFile.code), findsNothing);
  });

  testWidgets('尺寸页：锁定关闭再打开后，改宽仍联动高度', (tester) async {
    await _bootHome(tester, size: const ImageDimensions(400, 300));
    await _importImage(tester);
    await tester.tap(find.text('尺寸与比例'));
    await tester.pumpAndSettle();

    String fieldText(String label) => tester
        .widget<TextField>(find.widgetWithText(TextField, label))
        .controller!
        .text;

    final widthField = find.widgetWithText(TextField, '宽（px）');
    final lock = find.byIcon(Icons.link);

    // 默认锁定（原图 4:3）：400 → 300
    await tester.enterText(widthField, '200');
    await tester.pumpAndSettle();
    expect(fieldText('高（px）'), '150');

    // 关掉锁定后改宽，高度不动
    await tester.tap(lock);
    await tester.pumpAndSettle();
    await tester.enterText(widthField, '300');
    await tester.pumpAndSettle();
    expect(fieldText('高（px）'), '150');

    // 重新打开锁定：高度立刻对齐原图比 4:3（300 → 225）
    await tester.tap(lock);
    await tester.pumpAndSettle();
    expect(fieldText('高（px）'), '225');

    // 之后改宽仍按锁定比例联动：400 → 300
    await tester.enterText(widthField, '400');
    await tester.pumpAndSettle();
    expect(fieldText('高（px）'), '300');
  });

  testWidgets('尺寸页：裁剪后基准改为选区尺寸，锁定跟随裁剪比例', (tester) async {
    await _bootHome(tester, size: const ImageDimensions(400, 300));
    await _importImage(tester);

    // 裁成 200×200（原图 400×300，自由比例）
    await tester.tap(find.text('裁剪'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, '宽（px）'), '200');
    await tester.enterText(find.widgetWithText(TextField, '高（px）'), '200');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.textContaining('选区 x 100, y 50'), findsOneWidget);

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text('尺寸与比例'));
    await tester.pumpAndSettle();

    String fieldText(String label) => tester
        .widget<TextField>(find.widgetWithText(TextField, label))
        .controller!
        .text;

    // 基准是选区尺寸而不是原图 400×300
    expect(find.textContaining('裁剪后 200 × 200'), findsOneWidget);
    expect(fieldText('宽（px）'), '200');
    expect(fieldText('高（px）'), '200');

    // 锁定比例取 1:1，改宽 100 → 高 100（若仍按原图 4:3 会是 75）
    await tester.enterText(find.widgetWithText(TextField, '宽（px）'), '100');
    await tester.pumpAndSettle();
    expect(fieldText('高（px）'), '100');
  });

  testWidgets('M3：首页批量入口进入批量处理页', (tester) async {
    await _bootHome(tester);
    await tester.tap(find.text('批量处理（新）'));
    await tester.pumpAndSettle();
    expect(find.text('批量处理'), findsWidgets);
    expect(find.text('选择图片'), findsWidgets);
    expect(find.text('统一配置'), findsNothing); // 未选图不显示配置
  });

  testWidgets('尺寸页：重新打开锁定后，当前尺寸立即对齐锁定比例', (tester) async {
    await _bootHome(tester, size: const ImageDimensions(400, 300));
    await _importImage(tester);
    await tester.tap(find.text('尺寸与比例'));
    await tester.pumpAndSettle();

    String fieldText(String label) => tester
        .widget<TextField>(find.widgetWithText(TextField, label))
        .controller!
        .text;

    final widthField = find.widgetWithText(TextField, '宽（px）');
    final lock = find.byIcon(Icons.link);

    // 解锁后把宽拉到 800，高留在 300（画面严重拉扁）
    await tester.tap(lock);
    await tester.pumpAndSettle();
    await tester.enterText(widthField, '800');
    await tester.pumpAndSettle();
    expect(fieldText('高（px）'), '300');

    // 重新打开锁定：应立刻按锁定比例把高补成 600，而不是等下次输入
    await tester.tap(lock);
    await tester.pumpAndSettle();
    expect(fieldText('高（px）'), '600');
  });

  testWidgets('标注页：切换工具、拖拽创建、撤销重做', (tester) async {
    await _bootHome(tester, size: const ImageDimensions(128, 128));
    await _importImage(tester);

    await tester.tap(find.text('标注与打码'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('annotateCanvas')), findsOneWidget);
    for (final label in [
      '选择',
      '文字',
      '直线',
      '箭头',
      '矩形',
      '圆形',
      '椭圆',
      '马赛克',
      '涂抹打码',
      '头像块',
      '昵称条',
    ]) {
      expect(
        find.widgetWithText(ChoiceChip, label),
        findsOneWidget,
        reason: label,
      );
    }

    // 选矩形工具，在画布上拖出一个框
    await tester.tap(find.widgetWithText(ChoiceChip, '矩形'));
    await tester.pumpAndSettle();
    final rect = tester.getRect(find.byKey(const ValueKey('annotateCanvas')));
    await tester.dragFrom(
      Offset(rect.left + 80, rect.top + 80),
      const Offset(120, 100),
    );
    await tester.pumpAndSettle();

    final undo = find.byWidgetPredicate(
      (w) => w is IconButton && w.tooltip == '撤销 (Ctrl+Z)',
    );
    expect(
      tester.widget<IconButton>(undo).onPressed,
      isNotNull,
      reason: '创建标注后应可撤销',
    );

    await tester.tap(undo);
    await tester.pumpAndSettle();
    final clear = find.byWidgetPredicate(
      (w) => w is IconButton && w.tooltip == '清空标注',
    );
    expect(
      tester.widget<IconButton>(clear).onPressed,
      isNull,
      reason: '撤销后无标注，清空应禁用',
    );

    final redo = find.byWidgetPredicate(
      (w) => w is IconButton && w.tooltip == '重做 (Ctrl+Shift+Z)',
    );
    expect(tester.widget<IconButton>(redo).onPressed, isNotNull);
    await tester.tap(redo);
    await tester.pumpAndSettle();
    expect(
      tester.widget<IconButton>(clear).onPressed,
      isNotNull,
      reason: '重做后应有标注',
    );
  });

  testWidgets('标注页：涂抹打码工具可拖拽创建并进入属性条', (tester) async {
    await _bootHome(tester, size: const ImageDimensions(128, 128));
    await _importImage(tester);

    await tester.tap(find.text('标注与打码'));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(ChoiceChip, '涂抹打码'));
    await tester.pumpAndSettle();
    final rect = tester.getRect(find.byKey(const ValueKey('annotateCanvas')));
    await tester.dragFrom(
      Offset(rect.left + 40, rect.top + 60),
      const Offset(60, 0),
    );
    await tester.pumpAndSettle();

    // 创建后自动选中，属性条出现笔刷半径滑块与模式切换
    expect(find.text('笔刷'), findsOneWidget);
    expect(find.text('模糊'), findsWidgets);
  });

  testWidgets('标注页：整图模糊滑块可调且数值实时反映', (tester) async {
    await _bootHome(tester, size: const ImageDimensions(128, 128));
    await _importImage(tester);

    await tester.tap(find.text('标注与打码'));
    await tester.pumpAndSettle();

    expect(find.text('整图模糊'), findsOneWidget);
    final slider = find.byType(Slider);
    expect(slider, findsOneWidget, reason: '无选中标注时只有整图模糊一个滑块');
    // 拖到最右 → 显示 100
    await tester.drag(slider, const Offset(300, 0));
    await tester.pumpAndSettle();
    expect(find.text('100'), findsWidgets);
  });

  testWidgets('标注页：长图默认按宽度铺满，可切换回适应视图', (tester) async {
    // 高/宽 = 6，属于长图：默认 width 模式（顶对齐、可上下拖）
    await _bootHome(tester, size: const ImageDimensions(200, 1200));
    await _importImage(tester);
    await tester.tap(find.text('标注与打码'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('annotateCanvas')), findsOneWidget);
    expect(find.text('上下拖动查看'), findsOneWidget, reason: '长图应默认按宽度铺满');
    expect(find.text('双指/滚轮缩放'), findsNothing);

    // 视图条点击「适应」→ 整图塞进视口
    await tester.tap(find.text('适应'));
    await tester.pumpAndSettle();
    expect(find.text('双指/滚轮缩放'), findsOneWidget);
    expect(find.text('上下拖动查看'), findsNothing);
  });

  testWidgets('标注页：点按放码头像块/昵称条生成预设尺寸马赛克，命中已有块不再新建', (tester) async {
    await _bootHome(tester, size: const ImageDimensions(512, 512));
    await _importImage(tester);
    await tester.tap(find.text('标注与打码'));
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(Scaffold).first),
    );
    List<Annotation> anns() =>
        container.read(editorControllerProvider).annotations;
    final center = tester.getCenter(
      find.byKey(const ValueKey('annotateCanvas')),
    );

    // 头像块：单击落一个正方形马赛克。尺寸按屏幕像素反算到原图，
    // 故断言正方形 + 正方形比例，而非写死原图像素（分辨率无关）。
    await tester.tap(find.widgetWithText(ChoiceChip, '头像块'));
    await tester.pumpAndSettle();
    await tester.tapAt(center);
    await tester.pumpAndSettle();
    expect(anns().length, 1);
    final avatar = anns().last;
    expect(avatar.type, AnnotationType.mosaic, reason: '点按放码落到普通马赛克标注');
    expect(avatar.x2 - avatar.x1, avatar.y2 - avatar.y1, reason: '头像块应为正方形');

    // 关键修复：命中优先——再点同一处命中已有块本体，只移动不新建。
    // 头像块工具保持激活，但点已有块也不再生成第二个块。
    await tester.tapAt(center);
    await tester.pumpAndSettle();
    expect(anns().length, 1, reason: '命中已有块应进入移动，不应新建');

    // 昵称条：单击落一个横向宽条马赛克（宽显著大于高）。
    // 落点避开上面的头像块，否则命中优先会改为移动头像块。
    await tester.tap(find.widgetWithText(ChoiceChip, '昵称条'));
    await tester.pumpAndSettle();
    await tester.tapAt(center + const Offset(70, 0));
    await tester.pumpAndSettle();
    expect(anns().length, 2);
    final bar = anns().last;
    expect(bar.type, AnnotationType.mosaic);
    expect(bar.x2 - bar.x1, greaterThan(bar.y2 - bar.y1), reason: '昵称条应为横向宽条');

    // 复用现有管线：落块即选中，属性条出现马赛克「块」滑块；撤销可用
    expect(find.text('块'), findsOneWidget);
    final undo = find.byWidgetPredicate(
      (w) => w is IconButton && w.tooltip == '撤销 (Ctrl+Z)',
    );
    expect(tester.widget<IconButton>(undo).onPressed, isNotNull);
  });

  testWidgets('标注页：选中标注后拖动右下手柄可改变尺寸', (tester) async {
    await _bootHome(tester, size: const ImageDimensions(512, 512));
    await _importImage(tester);
    await tester.tap(find.text('标注与打码'));
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(Scaffold).first),
    );
    List<Annotation> anns() =>
        container.read(editorControllerProvider).annotations;

    // 矩形工具拖出一个框，落块后自动选中
    await tester.tap(find.widgetWithText(ChoiceChip, '矩形'));
    await tester.pumpAndSettle();
    final rect = tester.getRect(find.byKey(const ValueKey('annotateCanvas')));
    final start = Offset(rect.left + 80, rect.top + 80);
    const dragDelta = Offset(120, 100);
    await tester.dragFrom(start, dragDelta);
    await tester.pumpAndSettle();
    expect(anns().length, 1);
    final before = anns().last;
    expect(container.read(editorControllerProvider).selectedAnnotation, 0);

    // 右下手柄位于框的右下角屏幕坐标，向外拖 40px 应变大
    final br = start + dragDelta;
    await tester.dragFrom(br, const Offset(50, 40));
    await tester.pumpAndSettle();
    final after = anns().last;
    expect(after.x2, greaterThan(before.x2), reason: '拖动右下手柄应放大宽度');
    expect(after.y2, greaterThan(before.y2), reason: '拖动右下手柄应放大高度');
  });

  testWidgets('标注页：按住空格拖动只平移视图，不新建标注', (tester) async {
    await _bootHome(tester, size: const ImageDimensions(200, 1200));
    await _importImage(tester);
    await tester.tap(find.text('标注与打码'));
    await tester.pumpAndSettle();

    // 选矩形工具（不带空格时会创建），再按住空格拖动画布
    await tester.tap(find.widgetWithText(ChoiceChip, '矩形'));
    await tester.pumpAndSettle();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.space);
    final rect = tester.getRect(find.byKey(const ValueKey('annotateCanvas')));
    await tester.dragFrom(
      Offset(rect.left + rect.width / 2, rect.top + rect.height / 2),
      const Offset(0, -60),
    );
    await tester.pumpAndSettle();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.space);

    // 空格拖动只平移，撤销应始终保持禁用
    final undo = find.byWidgetPredicate(
      (w) => w is IconButton && w.tooltip == '撤销 (Ctrl+Z)',
    );
    expect(
      tester.widget<IconButton>(undo).onPressed,
      isNull,
      reason: '空格拖动不应创建标注',
    );
  });

  testWidgets('标注页：文字工具弹窗输入文案后放置，可再次编辑', (tester) async {
    await _bootHome(tester, size: const ImageDimensions(256, 256));
    await _importImage(tester);
    await tester.tap(find.text('标注与打码'));
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(Scaffold).first),
    );
    List<Annotation> anns() =>
        container.read(editorControllerProvider).annotations;

    await tester.tap(find.widgetWithText(ChoiceChip, '文字'));
    await tester.pumpAndSettle();
    final rect = tester.getRect(find.byKey(const ValueKey('annotateCanvas')));
    await tester.tapAt(Offset(rect.left + 60, rect.top + 60));
    await tester.pumpAndSettle();

    // 弹出输入框，未确认前不创建标注
    expect(find.text('添加文字标注'), findsOneWidget);
    expect(anns().isEmpty, isTrue, reason: '弹窗确认前不应凭空出现文字');

    await tester.enterText(find.byType(TextField).first, '你好世界');
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '添加'));
    await tester.pumpAndSettle();

    expect(anns().length, 1);
    expect(anns().last.type, AnnotationType.text);
    expect(anns().last.text, '你好世界');
    final placed = anns().last;
    expect(
      placed.x2 - placed.x1,
      CjkText.measureWidth('你好世界', placed.fontSize),
      reason: '框宽应与导出点阵字形等宽',
    );
    expect(
      placed.y2 - placed.y1,
      CjkText.measureInkHeight('你好世界', placed.fontSize),
      reason: '框高应与导出点阵占位等高',
    );

    // 文案只在放置弹窗里输入；字号改由画布四角手柄等比缩放，
    // 弹窗和属性条都不再出现字号滑块。
    expect(find.byKey(const ValueKey('annotationTextEdit')), findsNothing);
    expect(find.text('字号'), findsNothing);
  });

  testWidgets('标注页：滑块连续拖动只产生一次撤销', (tester) async {
    await _bootHome(tester, size: const ImageDimensions(256, 256));
    await _importImage(tester);
    await tester.tap(find.text('标注与打码'));
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(Scaffold).first),
    );
    List<Annotation> anns() =>
        container.read(editorControllerProvider).annotations;

    // 先画一个矩形并选中
    await tester.tap(find.widgetWithText(ChoiceChip, '矩形'));
    await tester.pumpAndSettle();
    final rect = tester.getRect(find.byKey(const ValueKey('annotateCanvas')));
    await tester.dragFrom(
      Offset(rect.left + 60, rect.top + 60),
      const Offset(80, 60),
    );
    await tester.pumpAndSettle();
    final initialWidth = anns().last.strokeWidth;

    // 拖动"线宽"滑块多次改变值（模拟连续手势）
    final lineWidthSlider = find.byWidgetPredicate(
      (w) => w is Slider && w.max == 20 && w.min == 1,
    );
    expect(lineWidthSlider, findsOneWidget);
    await tester.drag(lineWidthSlider, const Offset(60, 0));
    await tester.pumpAndSettle();
    expect(anns().last.strokeWidth, isNot(initialWidth), reason: '线宽应已改变');

    // 一次撤销即回到调整前的线宽（而非逐帧回退）
    final undo = find.byWidgetPredicate(
      (w) => w is IconButton && w.tooltip == '撤销 (Ctrl+Z)',
    );
    await tester.tap(undo);
    await tester.pumpAndSettle();
    expect(anns().last.strokeWidth, initialWidth, reason: '连续拖动应合并为一次撤销');
  });

  testWidgets('标注页：轻点文字本体弹编辑窗可改内容，拖动只定位不弹窗', (tester) async {
    await _bootHome(tester, size: const ImageDimensions(256, 256));
    await _importImage(tester);
    await tester.tap(find.text('标注与打码'));
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(Scaffold).first),
    );
    List<Annotation> anns() =>
        container.read(editorControllerProvider).annotations;

    // 文字工具创建一条文字（工具保持为文字，不切回选择）
    await tester.tap(find.widgetWithText(ChoiceChip, '文字'));
    await tester.pumpAndSettle();
    final rect = tester.getRect(find.byKey(const ValueKey('annotateCanvas')));
    await tester.tapAt(Offset(rect.left + 80, rect.top + 80));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, '昵称');
    await tester.tap(find.widgetWithText(FilledButton, '添加'));
    await tester.pumpAndSettle();
    expect(anns().length, 1);
    final textRect = tester.getRect(
      find.byKey(const ValueKey('annotateCanvas')),
    );
    final textBox = textRect.size;
    final textFit = textBox.width < textBox.height
        ? textBox.width
        : textBox.height;
    final textOrigin = Offset(
      (textBox.width - textFit) / 2,
      (textBox.height - textFit) / 2,
    );
    Offset textCenter(Annotation a) => Offset(
      textRect.left + textOrigin.dx + (a.x1 + a.x2) / 2 * textFit / 256,
      textRect.top + textOrigin.dy + (a.y1 + a.y2) / 2 * textFit / 256,
    );

    // 轻点文字本体中心（避开四角手柄）：命中优先 → 选中并弹编辑窗
    await tester.tapAt(textCenter(anns().first));
    await tester.pumpAndSettle();
    expect(find.text('编辑文字标注'), findsOneWidget, reason: '轻点文字应弹编辑窗');
    expect(
      container.read(editorControllerProvider).selectedAnnotation,
      0,
      reason: '点文字本体应选中它',
    );

    // 改内容并保存
    await tester.enterText(find.byType(TextField).first, '改名');
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();
    expect(anns().first.text, '改名', reason: '编辑应更新文字内容');
    expect(anns().length, 1, reason: '编辑不应新增标注');
    expect(
      find.byWidgetPredicate((w) => w is IconButton && w.tooltip == '颜色'),
      findsNothing,
      reason: '文字颜色在编辑弹窗里改，属性条不显示颜色按钮',
    );

    // 拖动文字本体可改变位置（x1 增大），且不弹编辑窗
    final before = anns().first.x1;
    await tester.dragFrom(textCenter(anns().first), const Offset(40, 0));
    await tester.pumpAndSettle();
    expect(anns().first.x1, greaterThan(before), reason: '文字应可整体拖动定位');
    expect(find.text('编辑文字标注'), findsNothing, reason: '拖动不应弹编辑窗');
  });

  testWidgets('标注页：文字四角手柄等比缩放，字号随框同步变化', (tester) async {
    await _bootHome(tester, size: const ImageDimensions(256, 256));
    await _importImage(tester);
    await tester.tap(find.text('标注与打码'));
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(Scaffold).first),
    );
    List<Annotation> anns() =>
        container.read(editorControllerProvider).annotations;

    await tester.tap(find.widgetWithText(ChoiceChip, '文字'));
    await tester.pumpAndSettle();
    final rect = tester.getRect(find.byKey(const ValueKey('annotateCanvas')));
    await tester.tapAt(Offset(rect.left + 60, rect.top + 60));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, '你好');
    await tester.tap(find.widgetWithText(FilledButton, '添加'));
    await tester.pumpAndSettle();
    expect(anns().length, 1);

    // 方形图按 contain 适配：屏幕坐标 = 画布左上角 + origin + 原图坐标 * fit/source
    final box = tester
        .getRect(find.byKey(const ValueKey('annotateCanvas')))
        .size;
    final fit = box.width < box.height ? box.width : box.height;
    final origin = Offset((box.width - fit) / 2, (box.height - fit) / 2);
    Offset screen(double x, double y) => Offset(
      rect.left + origin.dx + x * fit / 256,
      rect.top + origin.dy + y * fit / 256,
    );

    final before = anns().first;
    // 拖右下角手柄向外：字号变大、框变大，宽高比不变、对角（左上角）不动。
    await tester.dragFrom(
      screen(before.x2.toDouble(), before.y2.toDouble()),
      const Offset(40, 16),
    );
    await tester.pumpAndSettle();
    final after = anns().first;
    expect(after.fontSize, greaterThan(before.fontSize), reason: '拖角应放大字号');
    expect(after.x1, before.x1, reason: '拖右下角时左上角应保持不动');
    expect(after.y1, before.y1, reason: '拖右下角时左上角应保持不动');
    expect(after.x2 - after.x1, greaterThan(before.x2 - before.x1));
    expect(
      (after.x2 - after.x1) / (after.y2 - after.y1),
      closeTo((before.x2 - before.x1) / (before.y2 - before.y1), 0.15),
      reason: '整体缩放应保持宽高比不变',
    );
  });

  testWidgets('标注页：昵称条预设宽高比为 70:28', (tester) async {
    await _bootHome(tester, size: const ImageDimensions(512, 512));
    await _importImage(tester);
    await tester.tap(find.text('标注与打码'));
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(Scaffold).first),
    );
    List<Annotation> anns() =>
        container.read(editorControllerProvider).annotations;

    await tester.tap(find.widgetWithText(ChoiceChip, '昵称条'));
    await tester.pumpAndSettle();
    final center = tester.getCenter(
      find.byKey(const ValueKey('annotateCanvas')),
    );
    await tester.tapAt(center);
    await tester.pumpAndSettle();

    final bar = anns().single;
    // 屏幕 70×28 按视图缩放反算到原图，宽高各自取整会带来少量比例误差，
    // 只要接近 2.5 且显著横向即可（小尺寸下取整偏差可达 ~0.15）。
    expect(
      (bar.x2 - bar.x1) / (bar.y2 - bar.y1),
      closeTo(70 / 28, 0.2),
      reason: '昵称条宽高比应接近 70:28',
    );
  });

  testWidgets('标注页：顶部导出按钮进入导出面板', (tester) async {
    await _bootHome(tester, size: const ImageDimensions(256, 256));
    await _importImage(tester);
    await tester.tap(find.text('标注与打码'));
    await tester.pumpAndSettle();

    final export = find.widgetWithText(FilledButton, '导出');
    expect(export, findsOneWidget);
    await tester.tap(export);
    await tester.pumpAndSettle();
    expect(find.widgetWithText(FilledButton, '导出 PNG'), findsOneWidget);
  });

  testWidgets('标注页：属性条颜色弹窗用色块而不是十六进制串', (tester) async {
    await _bootHome(tester, size: const ImageDimensions(256, 256));
    await _importImage(tester);
    await tester.tap(find.text('标注与打码'));
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(Scaffold).first),
    );
    List<Annotation> anns() =>
        container.read(editorControllerProvider).annotations;

    await tester.tap(find.widgetWithText(ChoiceChip, '矩形'));
    await tester.pumpAndSettle();
    final rect = tester.getRect(find.byKey(const ValueKey('annotateCanvas')));
    await tester.dragFrom(
      Offset(rect.left + 60, rect.top + 60),
      const Offset(80, 60),
    );
    await tester.pumpAndSettle();

    final colorButton = find.byWidgetPredicate(
      (w) => w is IconButton && w.tooltip == '颜色',
    );
    expect(colorButton, findsOneWidget);
    await tester.tap(colorButton);
    await tester.pumpAndSettle();

    expect(find.text('标注颜色'), findsOneWidget);
    expect(find.text('ffff0000'), findsNothing, reason: '不再显示十六进制串');
    final swatches = find.byWidgetPredicate(
      (w) =>
          w is Container &&
          w.decoration is BoxDecoration &&
          (w.decoration as BoxDecoration).shape == BoxShape.circle,
    );
    expect(swatches, findsNWidgets(6), reason: '颜色应以 6 个色块展示');
    await tester.tap(swatches.at(2));
    await tester.pumpAndSettle();
    expect(anns().last.colorArgb, 0xFF2962FF, reason: '点色块应改标注颜色');
  });

  testWidgets('导出面板：GIF 动图开关仅对动图源显示并透传到编码', (tester) async {
    final encode = _RecordingEncodeService();
    await _bootHome(
      tester,
      importService: _FakeImportService(
        animated: true,
        format: ImageFormat.gif,
      ),
      encodeService: encode,
    );
    await _importImage(tester);
    await tester.tap(find.text('格式转换'));
    await tester.pumpAndSettle();

    final toggle = find.widgetWithText(SwitchListTile, '导出为动图');
    expect(toggle, findsOneWidget);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '导出 GIF'));
    await tester.pumpAndSettle();

    expect(encode.lastRequest, isNotNull);
    expect(encode.lastRequest!.format, ImageFormat.gif);
    expect(encode.lastRequest!.exportAnimation, isTrue, reason: '开关应透传到编码请求');
  });

  testWidgets('导出面板：静态源不显示 GIF 动图开关', (tester) async {
    await _bootHome(tester);
    await _importImage(tester);
    await tester.tap(find.text('格式转换'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(SwitchListTile, '导出为动图'), findsNothing);
  });
}
