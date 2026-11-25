import 'package:flutter_test/flutter_test.dart';
import 'package:image_format_factory/core/image/image_format.dart';
import 'package:image_format_factory/core/platform/app_platform.dart';
import 'package:image_format_factory/core/platform/capabilities.dart';
import 'package:image_format_factory/services/file/import_service.dart';

void main() {
  test('选择器同时给出扩展名与 MIME（Android 只认 MIME）', () {
    final group = ImportService(
      PlatformCapabilities.of(AppTarget.android),
    ).importTypeGroup();

    // 扩展名供桌面端过滤
    expect(group.extensions, contains('png'));
    expect(group.extensions, contains('jpg'));

    // MIME 供 Android 过滤；ico 必须显式给出，
    // 否则 MimeTypeMap 转不出来会被插件静默丢掉
    expect(group.mimeTypes, contains('image/x-icon'));
    expect(group.mimeTypes, contains('image/png'));
    expect(group.mimeTypes, contains('image/jpeg'));
  });

  test('选择器过滤条件与能力矩阵同源，不手写第二份清单', () {
    for (final target in AppTarget.values) {
      final caps = PlatformCapabilities.of(target);
      final group = ImportService(caps).importTypeGroup();

      expect(group.extensions!.toSet(), caps.importExtensions.toSet());
      expect(
        group.mimeTypes!.toSet(),
        {for (final f in caps.importFormats) f.mimeType},
      );
    }
  });

  test('每种可导入格式都有 MIME，不出现空值', () {
    for (final target in AppTarget.values) {
      final caps = PlatformCapabilities.of(target);
      for (final f in caps.importFormats) {
        expect(f.mimeType, contains('/'), reason: '${target.name} 的 ${f.name}');
      }
    }
  });
}
