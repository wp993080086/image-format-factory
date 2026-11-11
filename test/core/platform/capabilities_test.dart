import 'package:flutter_test/flutter_test.dart';
import 'package:pixel_forge/core/image/image_format.dart';
import 'package:pixel_forge/core/platform/app_platform.dart';
import 'package:pixel_forge/core/platform/capabilities.dart';

/// 能力矩阵与本 PRD 的一致性守卫（PRD 十章 / 九.3 / 十五章 DoD）。
///
/// 这些断言是「文档说支持、代码却没有」的反向保险：任何一端想偷偷放开
/// 一个没实现的能力，必须先改测试，也就必然要在 PRD 里同步。
void main() {
  final windows = PlatformCapabilities.of(AppTarget.windows);
  final android = PlatformCapabilities.of(AppTarget.android);
  final harmony = PlatformCapabilities.of(AppTarget.harmony);
  final web = PlatformCapabilities.of(AppTarget.web);
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
      for (final caps in [windows, android, harmony, web, mini]) {
        expect(caps.importFormats, mainstream, reason: caps.target.displayName);
      }
    });

    test('TIFF / TGA / PPM 全端关闭（附录 #8 已拍板移出 MVP）', () {
      for (final caps in [windows, android, harmony, web, mini]) {
        for (final f in ImageFormat.values.where((f) => f.isNiche)) {
          expect(caps.canImport(f), isFalse, reason: '${caps.target}-$f');
        }
      }
    });

    test('SVG 全端关闭（无光栅化能力，ADR-004 方案未接入）', () {
      for (final caps in [windows, android, harmony, web, mini]) {
        expect(caps.canImport(ImageFormat.svg), isFalse);
      }
    });

    test('扩展名并集与导入集合一致，不出现未支持格式', () {
      for (final caps in [windows, android, harmony, web, mini]) {
        final exts = caps.importExtensions.toSet();
        expect(exts.contains('svg'), isFalse);
        expect(exts.contains('tif'), isFalse);
        expect(exts.contains('tga'), isFalse);
        expect(exts.contains('ppm'), isFalse);
        // APNG 与 PNG 共用扩展名，故扩展名数量少于格式数量
        expect(exts, containsAll(['jpg', 'png', 'bmp', 'webp', 'gif', 'ico']));
      }
    });
  });

  group('导出（PRD 十章导出表）', () {
    test('WebP 全端不可导出（ADR-001）', () {
      for (final caps in [windows, android, harmony, web, mini]) {
        expect(caps.canExport(ImageFormat.webp), isFalse);
      }
    });

    test('ICO 仅 Web 与小程序之外的三端可导出', () {
      expect(windows.canExport(ImageFormat.ico), isTrue);
      expect(android.canExport(ImageFormat.ico), isTrue);
      expect(harmony.canExport(ImageFormat.ico), isTrue);
      expect(web.canExport(ImageFormat.ico), isFalse);
      expect(mini.canExport(ImageFormat.ico), isFalse);
    });

    test('JPEG / PNG / BMP 全端可导出', () {
      for (final caps in [windows, android, harmony, web, mini]) {
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
      expect(web.dragDropImport, isFalse);
      expect(mini.dragDropImport, isFalse);
    });

    test('粘贴导入仅 Web', () {
      expect(web.pasteImport, isTrue);
      for (final caps in [windows, android, harmony, mini]) {
        expect(caps.pasteImport, isFalse);
      }
    });

    test('系统保存面板：Web 与小程序没有', () {
      expect(windows.systemSavePanel, isTrue);
      expect(web.systemSavePanel, isFalse);
      expect(mini.systemSavePanel, isFalse);
    });
  });

  group('像素上限（PRD 九.3）', () {
    test('按端给出 100 / 32 / 50 / 16 MP', () {
      expect(windows.maxPixels, 100 * 1000 * 1000);
      expect(android.maxPixels, 32 * 1000 * 1000);
      expect(harmony.maxPixels, 32 * 1000 * 1000);
      // Web 取桌面浏览器上限；移动浏览器 16MP 需运行时判定（附录 #15）
      expect(web.maxPixels, 50 * 1000 * 1000);
      expect(mini.maxPixels, 16 * 1000 * 1000);
    });
  });
}
