// HEIF 原生解码能力入口（Windows 走 FFI 调 libheif，其余端无实现）。
//
// 条件导出：Web 端没有 `dart:ffi`，只能拿到空实现。
export 'heif_native_stub.dart' if (dart.library.ffi) 'heif_native_ffi.dart';
export 'heif_native_types.dart';
