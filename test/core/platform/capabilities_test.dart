import 'package:flutter_test/flutter_test.dart';
import 'package:image_format_factory/core/image/image_format.dart';
import 'package:image_format_factory/core/platform/app_platform.dart';
import 'package:image_format_factory/core/platform/capabilities.dart';

/// 能力矩阵与本 PRD 的一致性守卫（PRD 十章 / 九.3 / 十五章 DoD）。
///
/// 这些断言是「文档说支持、代码却没有」的反向保险：任何一端想偷偷放开
/// 一个没实现的能力，必须先改测试，也就必然要在 PRD 里同步。
void main() {
  final windows = PlatformCapabilities.of(AppTarget.windows);
  final android = PlatformCapabilities.of(AppTarget.android);
  final harmony = PlatformCapabilities.of(AppTarget.harmony);
  final mini = PlatformCapabilities.of(AppTarget.wechatMini);

  group('导入（PRD 十章导入表）', () {
    test('主流格式全端可导入', () {
      const mainstream = {
        ImageFormat.jpeg,
        ImageFormat.png,
        ImageFormat.bmp,
        ImageFormat.webp,
        ImageFormat.gif,
        ImageFormat.apng,
        ImageFormat.ico,
      };
      for (final caps in [windows, android, harmony, mini]) {
        expect(
          caps.importFormats,
          containsAll(mainstream),
          reason: caps.target.displayName,
        );
      }
    });

    test('HEIC/HEIF 在 Android 与 Windows 可导入', () {
      // Android：系统内置 HEVC 解码；Windows：随包分发 libheif
      expect(android.canImport(ImageFormat.heic), isTrue);
      expect(windows.canImport(ImageFormat.heic), isTrue);
      for (final caps in [harmony, mini]) {
        expect(
          caps.canImport(ImageFormat.heic),
          isFalse,
          reason: caps.target.displayName,
        );
      }
    });

    test('AVIF 导入：Windows 走 CLI、Android 走系统解码，其余端关闭', () {
      expect(windows.canImport(ImageFormat.avif), isTrue);
      expect(android.canImport(ImageFormat.avif), isTrue);
      for (final caps in [harmony, mini]) {
        expect(caps.canImport(ImageFormat.avif), isFalse);
      }
    });

    test('v0.5：TIFF 在 Windows/Android 导入，TGA/PPM 全端关闭', () {
      // TIFF 随 v0.5 优先级调整拉回（附录 #8 结论作废），仅双端先行
      expect(windows.canImport(ImageFormat.tiff), isTrue);
      expect(android.canImport(ImageFormat.tiff), isTrue);
      for (final caps in [harmony, mini]) {
        expect(
          caps.canImport(ImageFormat.tiff),
          isFalse,
          reason: '${caps.target}',
        );
      }
      // TGA / PPM 仍留需求池，全端关闭
      for (final caps in [windows, android, harmony, mini]) {
        expect(
          caps.canImport(ImageFormat.tga),
          isFalse,
          reason: '${caps.target}',
        );
        expect(
          caps.canImport(ImageFormat.ppm),
          isFalse,
          reason: '${caps.target}',
        );
      }
    });

    test('SVG 全端关闭（无光栅化能力，ADR-004 方案未接入）', () {
      for (final caps in [windows, android, harmony, mini]) {
        expect(caps.canImport(ImageFormat.svg), isFalse);
      }
    });

    test('扩展名并集与导入集合一致，不出现未支持格式', () {
      for (final caps in [windows, android, harmony, mini]) {
        final exts = caps.importExtensions.toSet();
        expect(exts.contains('svg'), isFalse);
        expect(exts.contains('tga'), isFalse);
        expect(exts.contains('ppm'), isFalse);
        // APNG 与 PNG 共用扩展名，故扩展名数量少于格式数量
        expect(exts, containsAll(['jpg', 'png', 'bmp', 'webp', 'gif', 'ico']));
        // v0.5：tif 只在 Windows/Android 的导入并集里
        if (caps.target == AppTarget.windows ||
            caps.target == AppTarget.android) {
          expect(exts, contains('tif'));
        } else {
          expect(exts, isNot(contains('tif')));
        }
      }
    });
  });

  group('导出（PRD 十章导出表）', () {
    test('WebP 在 Windows 与 Android 可导出，其余端关闭', () {
      // Windows：FFI 调 libwebp；Android：系统 Bitmap.compress(WEBP)
      expect(windows.canExport(ImageFormat.webp), isTrue);
      expect(android.canExport(ImageFormat.webp), isTrue);
      for (final caps in [harmony, mini]) {
        expect(
          caps.canExport(ImageFormat.webp),
          isFalse,
          reason: caps.target.displayName,
        );
      }
    });

    test('ICO 仅小程序之外的端可导出', () {
      expect(windows.canExport(ImageFormat.ico), isTrue);
      expect(android.canExport(ImageFormat.ico), isTrue);
      expect(harmony.canExport(ImageFormat.ico), isTrue);
      expect(mini.canExport(ImageFormat.ico), isFalse);
    });

    test('v0.5：TIFF/GIF 双端可导出，AVIF 仅 Windows 可导出', () {
      // TIFF：image 包纯 Dart 编码；GIF：静态/动图纯 Dart
      expect(windows.canExport(ImageFormat.tiff), isTrue);
      expect(android.canExport(ImageFormat.tiff), isTrue);
      expect(windows.canExport(ImageFormat.gif), isTrue);
      expect(android.canExport(ImageFormat.gif), isTrue);
      for (final caps in [harmony, mini]) {
        expect(caps.canExport(ImageFormat.tiff), isFalse);
        expect(caps.canExport(ImageFormat.gif), isFalse);
      }
      // AVIF：Windows 随包 avifenc CLI 可编码；Android 系统无 AVIF 编码器。
      expect(windows.canExport(ImageFormat.avif), isTrue);
      for (final caps in [android, harmony, mini]) {
        expect(
          caps.canExport(ImageFormat.avif),
          isFalse,
          reason: '${caps.target}',
        );
      }
    });

    test('JPEG / PNG / BMP 全端可导出', () {
      for (final caps in [windows, android, harmony, mini]) {
        expect(caps.canExport(ImageFormat.jpeg), isTrue);
        expect(caps.canExport(ImageFormat.png), isTrue);
        expect(caps.canExport(ImageFormat.bmp), isTrue);
      }
    });
  });

  group('端专属能力', () {
    test('拖拽导入仅 Windows', () {
      expect(windows.dragDropImport, isTrue);
      expect(android.dragDropImport, isFalse);
      expect(harmony.dragDropImport, isFalse);
      expect(mini.dragDropImport, isFalse);
    });

    test('系统保存面板：小程序没有', () {
      expect(windows.systemSavePanel, isTrue);
      expect(mini.systemSavePanel, isFalse);
    });

    test('系统保存面板：Android 已落地 SAF，鸿蒙待 M3（ADR-007）', () {
      expect(android.systemSavePanel, isTrue);
      // 鸿蒙无 SAF 等价物，share_plus 通道尚未接入，能力位如实关闭
      expect(harmony.systemSavePanel, isFalse);
    });

    test('GIF 逐帧重编码仅在 Windows / Android 开放', () {
      expect(windows.animatedReencode, isTrue);
      expect(android.animatedReencode, isTrue);
      for (final caps in [harmony, mini]) {
        expect(caps.animatedReencode, isFalse);
      }
    });
  });

  group('像素上限（PRD 九.3）', () {
    test('按端给出 100 / 32 / 16 MP', () {
      expect(windows.maxPixels, 100 * 1000 * 1000);
      expect(android.maxPixels, 32 * 1000 * 1000);
      expect(harmony.maxPixels, 32 * 1000 * 1000);
      expect(mini.maxPixels, 16 * 1000 * 1000);
    });
  });
}
