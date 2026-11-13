import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixel_forge/core/image/image_format.dart';
import 'package:pixel_forge/core/platform/app_platform.dart';
import 'package:pixel_forge/services/file/export_service.dart';

/// `flutter_file_dialog` 的方法通道名（插件里写死的常量）。
const MethodChannel _safChannel = MethodChannel('flutter_file_dialog');

/// `file_selector` 的方法通道名。
const MethodChannel _selectorChannel = MethodChannel(
  'plugins.flutter.io/file_selector',
);

/// 给方法通道挂替身；binding 在首次调用时才取，避免顶层求值。
void _mock(
  MethodChannel channel,
  Future<Object?>? Function(MethodCall)? handler,
) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, handler);
}

void main() {
  group('buildExportFileName（PRD 九.4）', () {
    test('JPEG 以质量为标识，扩展名归一到 jpg', () {
      expect(
        buildExportFileName(
          sourceFileName: 'photo.jpeg',
          format: ImageFormat.jpeg,
          quality: 85,
          width: 1200,
          height: 800,
        ),
        'photo_q85.jpg',
      );
    });

    test('PNG / BMP 以尺寸为标识', () {
      expect(
        buildExportFileName(
          sourceFileName: 'shot.png',
          format: ImageFormat.png,
          quality: 85,
          width: 2400,
          height: 1600,
        ),
        'shot_2400x1600.png',
      );
      expect(
        buildExportFileName(
          sourceFileName: 'shot.png',
          format: ImageFormat.bmp,
          quality: 85,
          width: 64,
          height: 64,
        ),
        'shot_64x64.bmp',
      );
    });

    test('ICO 无单一宽高，标识固定为 icon', () {
      expect(
        buildExportFileName(
          sourceFileName: 'logo.png',
          format: ImageFormat.ico,
          quality: 85,
          width: 256,
          height: 256,
        ),
        'logo_icon.ico',
      );
    });

    test('文件名无扩展名时直接追加标识', () {
      expect(
        buildExportFileName(
          sourceFileName: 'noext',
          format: ImageFormat.png,
          quality: 85,
          width: 10,
          height: 10,
        ),
        'noext_10x10.png',
      );
    });

    test('文件名含多个点时只截断最后一段', () {
      expect(
        buildExportFileName(
          sourceFileName: 'a.b.c.png',
          format: ImageFormat.png,
          quality: 85,
          width: 1,
          height: 1,
        ),
        'a.b.c_1x1.png',
      );
    });
  });

  group('导出通道分派（PRD 六.2 / ADR-007）', () {
    final safCalls = <MethodCall>[];
    final selectorCalls = <MethodCall>[];
    final bytes = Uint8List.fromList([1, 2, 3]);

    /// SAF 返回值可切换，用来模拟保存成功与用户取消。
    String? safResult;

    // binding 必须在用 messenger 之前初始化；helper 延迟到首次调用时才取
    setUpAll(TestWidgetsFlutterBinding.ensureInitialized);

    setUp(() {
      safCalls.clear();
      selectorCalls.clear();
      safResult = 'content://media/external/images/42';
      _mock(_safChannel, (call) async {
        safCalls.add(call);
        return call.method == 'saveFile' ? safResult : null;
      });
      _mock(_selectorChannel, (call) async {
        selectorCalls.add(call);
        return null;
      });
    });

    tearDown(() {
      _mock(_safChannel, null);
      _mock(_selectorChannel, null);
    });

    test('Android 走 SAF，携带文件名 / 字节 / MIME，且不碰 getSaveLocation', () async {
      const service = ExportService(target: AppTarget.android);

      final result = await service.save(
        ExportRequest(
          suggestedName: 'photo_800x600.png',
          bytes: bytes,
          format: ImageFormat.png,
        ),
      );

      // SAF 不暴露真实路径，返回的是 content:// URI
      expect(result?.savedPath, startsWith('content://'));
      expect(safCalls.map((c) => c.method), ['saveFile']);
      // 移动端 getSaveLocation 无实现，走 SAF 就必须一次都不调
      expect(selectorCalls, isEmpty);

      final args = safCalls.single.arguments as Map<Object?, Object?>;
      expect(args['fileName'], 'photo_800x600.png');
      expect(args['data'], bytes);
      expect(args['mimeTypesFilter'], const ['image/png']);
    });

    test('Android 用户取消返回 null（不算失败）', () async {
      safResult = null;
      const service = ExportService(target: AppTarget.android);

      final result = await service.save(
        ExportRequest(
          suggestedName: 'a.png',
          bytes: bytes,
          format: ImageFormat.png,
        ),
      );

      expect(result, isNull);
      expect(safCalls.map((c) => c.method), ['saveFile']);
    });

    test('Android 导出 ICO 用 image/x-icon 过滤', () async {
      const service = ExportService(target: AppTarget.android);

      await service.save(
        ExportRequest(
          suggestedName: 'a_icon.ico',
          bytes: bytes,
          format: ImageFormat.ico,
        ),
      );

      final args = safCalls.single.arguments as Map<Object?, Object?>;
      expect(args['mimeTypesFilter'], const ['image/x-icon']);
    });

    test('Android 导出诊断日志用 text/plain 过滤', () async {
      const service = ExportService(target: AppTarget.android);

      await service.saveAs(
        suggestedName: 'pixel-forge-log-1.txt',
        bytes: bytes,
        extensions: const ['txt'],
        label: '文本文件',
        mimeTypes: const ['text/plain'],
      );

      final args = safCalls.single.arguments as Map<Object?, Object?>;
      expect(args['mimeTypesFilter'], const ['text/plain']);
    });

    test('桌面端不走 SAF，仍走 file_selector 的保存位置', () async {
      const service = ExportService(target: AppTarget.windows);

      final result = await service.save(
        ExportRequest(
          suggestedName: 'a.png',
          bytes: bytes,
          format: ImageFormat.png,
        ),
      );

      // 系统面板返回 null（模拟取消），这里只验证走的是哪条通道
      expect(result, isNull);
      expect(safCalls, isEmpty);
      // 平台接口里 getSaveLocation 的默认实现会回落到 getSavePath，
      // 测试环境没有真实桌面插件，因此实际打过来的是后者
      expect(selectorCalls, isNotEmpty);
    });

    test('每个格式都有可用 MIME（SAF 过滤依赖它）', () {
      for (final f in ImageFormat.values) {
        expect(f.mimeType, contains('/'), reason: '${f.displayName} 的 MIME 无效');
      }
    });
  });

  group('保存位置展示（PRD 九.4）', () {
    test('SAF 的 content:// 不直接暴露给用户', () {
      expect(
        displaySavedPath('content://media/external/images/media/42'),
        '你选择的位置',
      );
    });

    test('桌面端显示真实路径', () {
      expect(
        displaySavedPath(r'C:\Users\me\Pictures\a.png'),
        r'C:\Users\me\Pictures\a.png',
      );
    });

    test('无路径时用兜底文案', () {
      expect(displaySavedPath(null), '你选择的位置');
      expect(displaySavedPath(null, fallback: '下载目录'), '下载目录');
    });
  });
}
