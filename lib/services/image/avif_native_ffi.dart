import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

// libavif 的 Windows FFI 绑定。
//
// 当前仓库尚未随包分发 libavif.dll（见 M3 执行手册），因此这里只声明符号、
// 不主动加载：只有当调用方显式传入 [libraryPath] 且文件存在时才 dlopen。
// 这样原生库一旦就位，无需改动上层即可启用；缺库时 [encodeAvifNative]
// 返回 null，由 AvifCodec 转成"不支持"，与 WebP/HEIF 的处理一致。

/// `int avifEncodeRgba(const uint8_t* rgba, int w, int h, int quality, uint8_t** out, int* outLen)`
/// 返回 0 表示成功，非 0 失败。内存由库内分配，用 avifFree 释放。
typedef _EncodeNative = Int32 Function(
  Pointer<Uint8> rgba,
  Int32 width,
  Int32 height,
  Int32 quality,
  Pointer<Pointer<Uint8>> out,
  Pointer<Int32> outLen,
);
typedef _EncodeDart = int Function(
  Pointer<Uint8>,
  int,
  int,
  int,
  Pointer<Pointer<Uint8>>,
  Pointer<Int32>,
);

typedef _FreeNative = Void Function(Pointer<Void> ptr);
typedef _FreeDart = void Function(Pointer<Void> ptr);

class _AvifBinding {
  _AvifBinding(this._lib) {
    _encode = _lib.lookupFunction<_EncodeNative, _EncodeDart>('avifEncodeRgba');
    _free = _lib.lookupFunction<_FreeNative, _FreeDart>('avifFree');
    // 解码符号可选：兼容只提供编码能力的库版本。
    try {
      _decode = _lib.lookupFunction<_DecodeNative, _DecodeDart>('avifDecode');
    } catch (_) {
      _decode = null;
    }
  }

  final DynamicLibrary _lib;
  late final _EncodeDart _encode;
  late final _FreeDart _free;
  _DecodeDart? _decode;
}

_AvifBinding? _binding;

bool get avifNativeAvailable => _binding != null;

/// 把 RGBA 像素编码为 AVIF。
///
/// [libraryPath] 为 libavif.dll 路径；未传或库不存在时返回 null。
/// 生产环境要启用需将 DLL 随包分发并在此处给默认路径（M3 后续）。
Uint8List? encodeAvifNative({
  required Uint8List rgba,
  required int width,
  required int height,
  required int quality,
  String? libraryPath,
}) {
  if (libraryPath == null) return null;
  _binding ??= _tryOpen(libraryPath);
  final binding = _binding;
  if (binding == null) return null;

  final inPtr = calloc<Uint8>(rgba.length);
  final outPtr = calloc<Pointer<Uint8>>();
  final outLen = calloc<Int32>();
  try {
    inPtr.asTypedList(rgba.length).setAll(0, rgba);
    final rc = binding._encode(
      inPtr,
      width,
      height,
      quality,
      outPtr,
      outLen,
    );
    if (rc != 0 || outPtr.value == nullptr || outLen.value <= 0) return null;
    return Uint8List.fromList(outPtr.value.asTypedList(outLen.value));
  } catch (_) {
    return null;
  } finally {
    if (outPtr.value != nullptr) binding._free(outPtr.value.cast<Void>());
    calloc.free(inPtr);
    calloc.free(outPtr);
    calloc.free(outLen);
  }
}

/// `int avifDecode(const uint8_t* data, int len, int maxPixels,
///     uint8_t** rgba, int* w, int* h)` —— 0 成功，非 0 失败/超限。
typedef _DecodeNative = Int32 Function(
  Pointer<Uint8> data,
  Int32 len,
  Int32 maxPixels,
  Pointer<Pointer<Uint8>> rgba,
  Pointer<Int32> w,
  Pointer<Int32> h,
);
typedef _DecodeDart = int Function(
  Pointer<Uint8>,
  int,
  int,
  Pointer<Pointer<Uint8>>,
  Pointer<Int32>,
  Pointer<Int32>,
);

/// AVIF 解码结果。
class AvifNativeDecode {
  const AvifNativeDecode.success(this.rgba, this.width, this.height)
    : error = null;
  const AvifNativeDecode.failed() : rgba = null, width = 0, height = 0, error = true;

  final Uint8List? rgba;
  final int width;
  final int height;
  final bool? error;
  bool get isSuccess => rgba != null;
}

/// 解码 AVIF 为 RGBA。库缺失或解码失败时返回 [AvifNativeDecode.failed]。
AvifNativeDecode decodeAvifNative(
  Uint8List bytes, {
  required int maxPixels,
  String? libraryPath,
}) {
  if (libraryPath == null) return const AvifNativeDecode.failed();
  _binding ??= _tryOpen(libraryPath);
  final binding = _binding;
  if (binding == null) return const AvifNativeDecode.failed();
  if (binding._decode == null) return const AvifNativeDecode.failed();

  final inPtr = calloc<Uint8>(bytes.length);
  final outPtr = calloc<Pointer<Uint8>>();
  final wPtr = calloc<Int32>();
  final hPtr = calloc<Int32>();
  try {
    inPtr.asTypedList(bytes.length).setAll(0, bytes);
    final rc = binding._decode!(inPtr, bytes.length, maxPixels, outPtr, wPtr, hPtr);
    if (rc != 0 || outPtr.value == nullptr) {
      return const AvifNativeDecode.failed();
    }
    final w = wPtr.value;
    final h = hPtr.value;
    return AvifNativeDecode.success(
      Uint8List.fromList(outPtr.value.asTypedList(w * h * 4)),
      w,
      h,
    );
  } catch (_) {
    return const AvifNativeDecode.failed();
  } finally {
    if (outPtr.value != nullptr) binding._free(outPtr.value.cast<Void>());
    calloc.free(inPtr);
    calloc.free(outPtr);
    calloc.free(wPtr);
    calloc.free(hPtr);
  }
}

_AvifBinding? _tryOpen(String path) {
  try {
    return _AvifBinding(DynamicLibrary.open(path));
  } catch (_) {
    return null;
  }
}
