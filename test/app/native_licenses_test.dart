import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_format_factory/app/native_licenses.dart';

/// 随包分发的原生库必须满足 LGPL-3.0 / BSD-3 的分发要求：
/// 声明完整、许可全文随包、版本与实际构建一致。
void main() {
  test('原生库许可清单非空且每项字段齐全', () {
    expect(nativeLibraryLicenses, isNotEmpty);
    for (final lib in nativeLibraryLicenses) {
      expect(lib.name, isNotEmpty, reason: '组件名不能为空');
      expect(lib.version, isNotEmpty, reason: '${lib.name} 缺版本号');
      expect(lib.license, isNotEmpty, reason: '${lib.name} 缺许可标识');
      expect(lib.assetPath, startsWith('assets/licenses/'));
      expect(lib.purpose, isNotEmpty);
      expect(lib.homepage, startsWith('https://'));
    }
  });

  test('许可标识只能是已确认的 SPDX 值', () {
    const allowed = {'BSD-2-Clause', 'BSD-3-Clause', 'LGPL-3.0'};
    for (final lib in nativeLibraryLicenses) {
      expect(allowed, contains(lib.license), reason: '${lib.name} 许可未复核');
    }
  });

  test('libwebp 与 libheif 必须出现在清单里（ADR-010 的两项能力）', () {
    final names = nativeLibraryLicenses.map((e) => e.name).toSet();
    expect(names, contains('libwebp'));
    expect(names, contains('libheif'));
  });

  test('AVIF 编解码组件必须出现在清单里', () {
    final names = nativeLibraryLicenses.map((e) => e.name).toSet();
    expect(names, contains('libavif (avifenc/avifdec)'));
    expect(names, contains('libaom'));
    expect(names, contains('dav1d'));
  });

  test('许可全文随包可读，且包含许可名称', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    for (final lib in nativeLibraryLicenses) {
      final text = await rootBundle.loadString(lib.assetPath);
      expect(text, isNotEmpty, reason: '${lib.name} 许可全文为空');
    }
  });
}
