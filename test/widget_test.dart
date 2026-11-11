import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixel_forge/app/app.dart';
import 'package:pixel_forge/core/di/providers.dart';
import 'package:pixel_forge/core/image/decode_service.dart';
import 'package:pixel_forge/core/image/image_format.dart';
import 'package:pixel_forge/core/image/image_header_probe.dart';
import 'package:pixel_forge/core/platform/app_platform.dart';
import 'package:pixel_forge/core/platform/capabilities.dart';
import 'package:pixel_forge/services/file/import_service.dart';

/// 导入/解码替身：返回一张 4×4 的假图，避免测试依赖真实文件选择器与解码。
class _FakeImportService extends ImportService {
  _FakeImportService() : super(PlatformCapabilities.of(AppTarget.windows));

  @override
  Future<ImportResult?> pickImage() async => ImportResult(
    fileName: 'a.png',
    bytes: Uint8List.fromList([1, 2, 3]),
    format: ImageFormat.png,
    isAnimated: false,
    extensionMismatch: false,
  );
}

class _FakeDecodeService extends DecodeService {
  const _FakeDecodeService([this.size = const ImageDimensions(4, 4)]);

  /// 伪造的原图尺寸，供 ICO 尺寸矩阵等依赖真实宽高的用例切换。
  final ImageDimensions size;

  @override
  Future<DecodeResult?> decodePreview(Uint8List bytes) async => DecodeResult(
    previewPng: _onePixelPng,
    sourceSize: size,
    previewSize: size,
  );
}

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
  Size viewSize = const Size(1000, 1400),
}) async {
  // 裁剪页底部参数面板较高，默认 800×600 视口会把画布压到溢出
  tester.view.physicalSize = viewSize;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        importServiceProvider.overrideWithValue(_FakeImportService()),
        decodeServiceProvider.overrideWithValue(_FakeDecodeService(size)),
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
}
