/// 随包分发的原生库许可信息（Windows 端，ADR-010）。
///
/// 为什么单独列：`showLicensePage` 只汇总 pubspec 里的 Dart 包，
/// libwebp / libheif / libde265 是编译进发布目录的 DLL，不在其中。
/// LGPL-3.0 要求分发时附带许可全文，所以这里显式声明并在关于页可查。
library;

/// 单个原生库的许可条目。
class NativeLibraryLicense {
  const NativeLibraryLicense({
    required this.name,
    required this.version,
    required this.license,
    required this.assetPath,
    required this.purpose,
    required this.homepage,
  });

  /// 组件名，如 `libwebp`。
  final String name;

  /// 锁定版本，如 `1.4.0`。
  final String version;

  /// SPDX 许可标识。
  final String license;

  /// 许可全文在 assets 下的路径。
  final String assetPath;

  /// 在本项目里承担什么能力。
  final String purpose;

  /// 上游主页。
  final String homepage;
}

/// Windows 端随包分发的原生库清单。
///
/// Android 端不依赖这些库（HEIC 用系统 `BitmapFactory`、
/// WebP 用系统 `Bitmap.compress`），因此清单只覆盖 Windows。
const List<NativeLibraryLicense> nativeLibraryLicenses = [
  NativeLibraryLicense(
    name: 'libwebp',
    version: '1.4.0',
    license: 'BSD-3-Clause',
    assetPath: 'assets/licenses/libwebp-LICENSE.txt',
    purpose: 'WebP 编码（纯 Dart 的 image 包只有解码器）',
    homepage: 'https://github.com/webmproject/libwebp',
  ),
  NativeLibraryLicense(
    name: 'libsharpyuv',
    version: '1.4.0',
    license: 'BSD-3-Clause',
    assetPath: 'assets/licenses/libwebp-LICENSE.txt',
    purpose: 'libwebp 的 RGB→YUV 转换依赖，随 libwebp 一并分发',
    homepage: 'https://github.com/webmproject/libwebp',
  ),
  NativeLibraryLicense(
    name: 'libheif',
    version: '1.18.2',
    license: 'LGPL-3.0',
    assetPath: 'assets/licenses/libheif-LICENSE.txt',
    purpose: 'HEIC / HEIF 容器解析（Windows 系统无 HEVC 解码组件）',
    homepage: 'https://github.com/strukturag/libheif',
  ),
  NativeLibraryLicense(
    name: 'libde265',
    version: '1.0.15',
    license: 'LGPL-3.0',
    assetPath: 'assets/licenses/libde265-LICENSE.txt',
    purpose: 'HEVC 解码（静态链接进 libheif，只解码不编码）',
    homepage: 'https://github.com/strukturag/libde265',
  ),
];
