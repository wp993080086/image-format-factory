import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

/// `WebPEncodeRGBA(const uint8_t* rgba, int w, int h, int stride, float quality, uint8_t** output)`
typedef _EncodeRgbaNative = IntPtr Function(
  Pointer<Uint8> rgba,
  Int32 width,
  Int32 height,
  Int32 stride,
  Float quality,
  Pointer<Pointer<Uint8>> output,
);
typedef _EncodeRgbaDart = int Function(
  Pointer<Uint8>,
  int,
  int,
  int,
  double,
  Pointer<Pointer<Uint8>>,
);

/// `WebPEncodeLosslessRGBA(const uint8_t* rgba, int w, int h, int stride, uint8_t** output)`
typedef _EncodeLosslessNative = IntPtr Function(
  Pointer<Uint8> rgba,
  Int32 width,
  Int32 height,
  Int32 stride,
  Pointer<Pointer<Uint8>> output,
);
typedef _EncodeLosslessDart = int Function(
  Pointer<Uint8>,
  int,
  int,
  int,
  Pointer<Pointer<Uint8>>,
);

/// `void WebPFree(void* ptr)`——libwebp 分配的内存必须用它释放，不能用 free。
typedef _WebpFreeNative = Void Function(Pointer<Uint8> ptr);
typedef _WebpFreeDart = void Function(Pointer<Uint8> ptr);

class _WebpBinding {
  _WebpBinding(this._lib) {
    _encodeRgba = _lib.lookupFunction<_EncodeRgbaNative, _EncodeRgbaDart>(
      'WebPEncodeRGBA',
    );
    _encodeLossless = _lib.lookupFunction<
      _EncodeLosslessNative,
      _EncodeLosslessDart
    >('WebPEncodeLosslessRGBA');
    _free = _lib.lookupFunction<_WebpFreeNative, _WebpFreeDart>('WebPFree');
  }

  final DynamicLibrary _lib;
  late final _EncodeRgbaDart _encodeRgba;
  late final _EncodeLosslessDart _encodeLossless;
  late final _WebpFreeDart _free;
}

_WebpBinding? _binding;

/// libwebp.dll 的有损编码要调 libsharpyuv.dll 做 RGB→YUV 转换。
///
/// Windows 解析 DLL 依赖时，搜索的是「exe 所在目录」而不是「webp.dll 所在
/// 目录」——两者同目录时恰好能命中，但只要 webp.dll 是按绝对路径加载的，
/// 依赖就找不到。这里先按短名把依赖加载进来，Windows 会按模块名命中已加载
/// 的那份，绕开搜索路径的差异。
void _preloadDependency() {
  try {
    DynamicLibrary.open('libsharpyuv.dll');
  } on ArgumentError {
    // 没有就不预加载，后续加载 webp.dll 时再失败
  }
}

/// 载入 libwebp 动态库。
///
/// 优先 `webp.dll`（我们自建时用的名字），再退回 `libwebp.dll`
/// （vcpkg 等发行版的命名）。两者都找不到就是「本机没装」，返回 null。
///
/// [libraryPath] 仅供测试注入绝对路径：测试进程的可执行文件在 SDK 缓存里，
/// 不在 exe 同目录，按短名找不到随包分发的 DLL。
_WebpBinding? _load([String? libraryPath]) {
  if (_binding != null) return _binding;
  final candidates = <String>[
    ?libraryPath,
    'webp.dll',
    'libwebp.dll',
  ];
  for (final name in candidates) {
    try {
      _preloadDependency();
      final lib = DynamicLibrary.open(name);
      _binding = _WebpBinding(lib);
      return _binding;
    } on ArgumentError {
      continue;
    }
  }
  return null;
}

/// 当前进程能否调用 libwebp。
bool get webpNativeAvailable => _load() != null;

/// 用 libwebp 把 RGBA 像素编码为 WebP。
///
/// [rgba] 必须是 `width * height * 4` 字节的 RGBA 顺序像素；
/// [quality] 为 0–100，对应 libwebp 的 quality_factor。
/// 返回 null 表示本端没有 libwebp 或编码失败。
Uint8List? encodeWebpNative({
  required Uint8List rgba,
  required int width,
  required int height,
  required int quality,
  required bool lossless,
  String? libraryPath,
}) {
  final binding = _load(libraryPath);
  if (binding == null) return null;
  if (width <= 0 || height <= 0) return null;
  if (rgba.length < width * height * 4) return null;

  final input = calloc<Uint8>(rgba.length);
  final output = calloc<Pointer<Uint8>>(1);
  try {
    input.asTypedList(rgba.length).setAll(0, rgba);
    final size = lossless
        ? binding._encodeLossless(input, width, height, width * 4, output)
        : binding._encodeRgba(
            input,
            width,
            height,
            width * 4,
            quality.toDouble(),
            output,
          );
    if (size <= 0) return null;
    final pointer = output.value;
    if (pointer == nullptr) return null;
    try {
      return Uint8List.fromList(pointer.asTypedList(size));
    } finally {
      binding._free(pointer);
    }
  } finally {
    calloc
      ..free(output)
      ..free(input);
  }
}
