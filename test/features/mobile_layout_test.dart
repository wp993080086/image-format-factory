import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixel_forge/app/app.dart';
import 'package:pixel_forge/core/di/providers.dart';
import 'package:pixel_forge/core/image/decode_service.dart';
import 'package:pixel_forge/core/image/encode_service.dart';
import 'package:pixel_forge/core/image/image_format.dart';
import 'package:pixel_forge/core/image/image_header_probe.dart';
import 'package:pixel_forge/core/platform/app_platform.dart';
import 'package:pixel_forge/core/platform/capabilities.dart';
import 'package:pixel_forge/services/file/export_service.dart';
import 'package:pixel_forge/services/file/import_service.dart';

/// 移动端布局守卫（PRD 七.1 / 十）。
///
/// M1 的页面是按桌面窗口设计的，M2 要在 360dp 级手机上跑。这里把「四页在
/// 常见手机竖屏尺寸下不产生 RenderFlex 溢出」固化成断言——溢出属于
/// 回归即红的问题，靠人眼在真机上看容易漏。
class _FakeImportService extends ImportService {
  _FakeImportService() : super(PlatformCapabilities.of(AppTarget.android));

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
  const _FakeDecodeService();

  @override
  Future<DecodeResult?> decodePreview(Uint8List bytes) async => DecodeResult(
    previewPng: _onePixelPng,
    // 用 1200×900 而不是 4×4：手机上面的参数面板会显示真实量级尺寸，
    // 更容易暴露输入框 / 提示文案的换行溢出
    sourceSize: const ImageDimensions(1200, 900),
    previewSize: const ImageDimensions(1200, 900),
    // 半透明源会让 PNG 调色板开关进入禁用态，禁用态文案也要一起验
    hasSemiTransparent: true,
  );
}

class _RecordingEncodeService extends EncodeService {
  @override
  Future<EncodeResult?> encode(EncodeRequest request) async => EncodeResult(
    bytes: _onePixelPng,
    size: const ImageDimensions(1200, 900),
    alphaFlattened: false,
  );
}

class _FakeExportService extends ExportService {
  @override
  Future<ExportResult?> save(ExportRequest request) async =>
      const ExportResult(savedPath: '/tmp/out.png');
}

/// 一张真实的 1×1 透明 PNG，供 `Image.memory` 正常解码。
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

Future<void> _boot(
  WidgetTester tester,
  Size size, {
  double textScale = 1.0,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  // PRD 九.6：系统字号放大至 1.3× 不破版
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        importServiceProvider.overrideWithValue(_FakeImportService()),
        decodeServiceProvider.overrideWithValue(const _FakeDecodeService()),
        exportServiceProvider.overrideWithValue(_FakeExportService()),
        encodeServiceProvider.overrideWithValue(_RecordingEncodeService()),
        diagnosticsProvider.overrideWithValue(
          ({String header = ''}) async => '$header\n（测试会话）',
        ),
      ],
      child: const PixelForgeApp(),
    ),
  );
  await tester.pumpAndSettle();
}

/// 走完四页并在每步后确认没有布局溢出。
Future<void> _walkAllPages(WidgetTester tester) async {
  // 首页 → 导入
  await tester.tap(find.text('选择文件'));
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull, reason: '导入后首页溢出');

  // 裁剪页
  await tester.tap(find.text('裁剪'));
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull, reason: '裁剪页溢出');
  await tester.tap(find.byType(BackButton));
  await tester.pumpAndSettle();

  // 尺寸与比例页
  await tester.tap(find.text('尺寸与比例'));
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull, reason: '尺寸页溢出');
  await tester.tap(find.byType(BackButton));
  await tester.pumpAndSettle();

  // 导出面板
  await tester.tap(find.text('格式转换'));
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull, reason: '导出面板溢出');
}

void main() {
  testWidgets('360×740（主流安卓竖屏）：四页均无布局溢出', (tester) async {
    await _boot(tester, const Size(360, 740));
    await _walkAllPages(tester);
  });

  testWidgets('412×915（大屏安卓）：四页均无布局溢出', (tester) async {
    await _boot(tester, const Size(412, 915));
    await _walkAllPages(tester);
  });

  testWidgets('手机视口下导出面板仍提供全部格式入口', (tester) async {
    await _boot(tester, const Size(360, 740));
    await tester.tap(find.text('选择文件'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('格式转换'));
    await tester.pumpAndSettle();

    expect(find.text('输出格式'), findsOneWidget);
    // 手机上也不能把格式选项挤掉
    expect(find.text('PNG'), findsWidgets);
  });

  group('系统字号 1.3×（PRD 九.6）', () {
    testWidgets('桌面视口：四页均无溢出', (tester) async {
      await _boot(tester, const Size(1000, 1400), textScale: 1.3);
      await _walkAllPages(tester);
    });

    testWidgets('手机视口：四页均无溢出', (tester) async {
      await _boot(tester, const Size(360, 740), textScale: 1.3);
      await _walkAllPages(tester);
    });
  });
}
