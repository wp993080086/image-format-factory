// WebP 原生编码能力入口（Windows 走 FFI，Web 端无实现）。
//
// 条件导出：Web 端没有 `dart:ffi`，只能拿到空实现。
export 'webp_native_stub.dart' if (dart.library.ffi) 'webp_native_ffi.dart';
