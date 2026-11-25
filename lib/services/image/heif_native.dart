// HEIF 原生解码能力入口（Windows 走 FFI 调 libheif，Android 走系统通道）。
//
// 直接导出 FFI 实现：Windows / Android 均支持 dart:ffi。
export 'heif_native_ffi.dart';
export 'heif_native_types.dart';
