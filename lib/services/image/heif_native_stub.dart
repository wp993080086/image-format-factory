import 'dart:typed_data';

import 'heif_native_types.dart';

/// 非原生平台没有 libheif，无法解码 HEIF。
///
/// HEVC 解码没有纯 Dart 实现（ADR-009），Web 端当前只做识别与提示。
///
/// [libraryPath] 仅供测试注入；本实现没有原生库，参数保留只为与
/// FFI 版本签名一致（条件导出要求两侧签名相同）。
HeifNativeDecode decodeHeifNative(
  Uint8List bytes, {
  required int maxPixels,
  String? libraryPath,
}) => const HeifNativeDecode.failed();
