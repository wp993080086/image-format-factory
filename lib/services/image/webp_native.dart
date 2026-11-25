// WebP 原生编码能力入口（Windows 走 FFI，Android 走系统通道）。
//
// 直接导出 FFI 实现：Windows / Android 均支持 dart:ffi。
export 'webp_native_ffi.dart';
