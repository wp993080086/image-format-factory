// AVIF 原生编解码能力入口（Windows 走 FFI，Web 端无实现）。
//
// 条件导出：Web 端没有 dart:ffi，只能拿到空实现。
export 'avif_native_stub.dart' if (dart.library.ffi) 'avif_native_ffi.dart';
