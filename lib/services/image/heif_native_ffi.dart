import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'heif_native_types.dart';

/// libheif 的 `struct heif_error`：三个字段，按值返回。
///
/// C 侧定义：
/// ```c
/// struct heif_error {
///   enum heif_error_code code;      // int
///   enum heif_suberror_code subcode;// int
///   const char* message;            // 指针
/// };
/// ```
final class _HeifError extends Struct {
  @Int32()
  external int code;

  @Int32()
  external int subcode;

  external Pointer<Utf8> message;
}

typedef _ContextAllocNative = Pointer<Void> Function();
typedef _ContextAllocDart = Pointer<Void> Function();

typedef _ContextFreeNative = Void Function(Pointer<Void>);
typedef _ContextFreeDart = void Function(Pointer<Void>);

typedef _ReadMemoryNative = _HeifError Function(
  Pointer<Void> context,
  Pointer<Void> data,
  IntPtr size,
  Pointer<Void> options,
);
typedef _ReadMemoryDart = _HeifError Function(
  Pointer<Void>,
  Pointer<Void>,
  int,
  Pointer<Void>,
);

typedef _PrimaryHandleNative = _HeifError Function(
  Pointer<Void> context,
  Pointer<Pointer<Void>> outHandle,
);
typedef _PrimaryHandleDart = _HeifError Function(
  Pointer<Void>,
  Pointer<Pointer<Void>>,
);

typedef _HandleExtentNative = Int32 Function(Pointer<Void> handle, Int32 channel);
typedef _HandleExtentDart = int Function(Pointer<Void>, int);

typedef _DecodeImageNative = _HeifError Function(
  Pointer<Void> handle,
  Pointer<Pointer<Void>> outImage,
  Int32 colorspace,
  Int32 chroma,
  Pointer<Void> options,
);
typedef _DecodeImageDart = _HeifError Function(
  Pointer<Void>,
  Pointer<Pointer<Void>>,
  int,
  int,
  Pointer<Void>,
);

typedef _PlaneNative = Pointer<Uint8> Function(
  Pointer<Void> image,
  Int32 channel,
  Pointer<Int32> outStride,
);
typedef _PlaneDart = Pointer<Uint8> Function(
  Pointer<Void>,
  int,
  Pointer<Int32>,
);

typedef _ImageReleaseNative = Void Function(Pointer<Void>);
typedef _ImageReleaseDart = void Function(Pointer<Void>);

/// libheif 枚举值（取自 libheif/heif.h）。
const int _errorOk = 0;
const int _colorspaceRgb = 1;
const int _chromaInterleavedRgba = 11;
const int _channelInterleaved = 10;

class _HeifBinding {
  _HeifBinding(this._lib) {
    _contextAlloc = _lib
        .lookupFunction<_ContextAllocNative, _ContextAllocDart>(
          'heif_context_alloc',
        );
    _contextFree = _lib.lookupFunction<_ContextFreeNative, _ContextFreeDart>(
      'heif_context_free',
    );
    _readMemory =
        _lib.lookupFunction<_ReadMemoryNative, _ReadMemoryDart>(
          'heif_context_read_from_memory_without_copy',
        );
    _primaryHandle =
        _lib.lookupFunction<_PrimaryHandleNative, _PrimaryHandleDart>(
          'heif_context_get_primary_image_handle',
        );
    _handleWidth =
        _lib.lookupFunction<_HandleExtentNative, _HandleExtentDart>(
          'heif_image_handle_get_width',
        );
    _handleHeight =
        _lib.lookupFunction<_HandleExtentNative, _HandleExtentDart>(
          'heif_image_handle_get_height',
        );
    _decodeImage = _lib.lookupFunction<_DecodeImageNative, _DecodeImageDart>(
      'heif_decode_image',
    );
    _plane = _lib.lookupFunction<_PlaneNative, _PlaneDart>(
      'heif_image_get_plane_readonly',
    );
    _imageRelease =
        _lib.lookupFunction<_ImageReleaseNative, _ImageReleaseDart>(
          'heif_image_release',
        );
  }

  final DynamicLibrary _lib;
  late final _ContextAllocDart _contextAlloc;
  late final _ContextFreeDart _contextFree;
  late final _ReadMemoryDart _readMemory;
  late final _PrimaryHandleDart _primaryHandle;
  late final _HandleExtentDart _handleWidth;
  late final _HandleExtentDart _handleHeight;
  late final _DecodeImageDart _decodeImage;
  late final _PlaneDart _plane;
  late final _ImageReleaseDart _imageRelease;
}

_HeifBinding? _binding;

/// 载入 libheif 动态库。
///
/// [libraryPath] 仅供测试注入绝对路径：测试进程的可执行文件在 SDK 缓存里，
/// 不在 exe 同目录，按短名找不到随包分发的 DLL。
_HeifBinding? _load([String? libraryPath]) {
  if (_binding != null) return _binding;
  final candidates = <String>[
    ?libraryPath,
    'heif.dll',
    'libheif.dll',
  ];
  for (final name in candidates) {
    try {
      final lib = DynamicLibrary.open(name);
      _binding = _HeifBinding(lib);
      return _binding;
    } on ArgumentError {
      continue;
    }
  }
  return null;
}

/// 当前进程能否调用 libheif。
bool get heifNativeAvailable => _load() != null;

/// 用 libheif 解码 HEIC/HEIF，返回 RGBA 像素。
///
/// [maxPixels] 是本端像素上限：超限时在**解码前**就返回，
/// 连位图都不分配——HEVC 解码一张 12MP 照片要上百 MB 内存。
///
/// libheif 的 `read_from_memory_without_copy` 不复制输入，所以字节缓冲区
/// 必须活到解码结束，这里用 calloc 显式持有并在 finally 里释放。
HeifNativeDecode decodeHeifNative(
  Uint8List bytes, {
  required int maxPixels,
  String? libraryPath,
}) {
  final binding = _load(libraryPath);
  if (binding == null) return const HeifNativeDecode.failed();
  if (bytes.isEmpty) return const HeifNativeDecode.failed();

  final input = calloc<Uint8>(bytes.length);
  final context = binding._contextAlloc();
  if (context == nullptr) {
    calloc.free(input);
    return const HeifNativeDecode.failed();
  }

  Pointer<Void> image = nullptr;
  try {
    input.asTypedList(bytes.length).setAll(0, bytes);
    final readError = binding._readMemory(
      context,
      input.cast(),
      bytes.length,
      nullptr,
    );
    if (readError.code != _errorOk) {
      return const HeifNativeDecode.failed();
    }

    final handleHolder = calloc<Pointer<Void>>(1);
    try {
      final handleError = binding._primaryHandle(context, handleHolder);
      if (handleError.code != _errorOk) {
        return const HeifNativeDecode.failed();
      }
      final handle = handleHolder.value;

      final width = binding._handleWidth(handle, _channelInterleaved);
      final height = binding._handleHeight(handle, _channelInterleaved);
      if (width <= 0 || height <= 0) {
        return const HeifNativeDecode.failed();
      }
      if (maxPixels > 0 && width * height > maxPixels) {
        return const HeifNativeDecode.pixelLimit();
      }

      final imageHolder = calloc<Pointer<Void>>(1);
      try {
        final decodeError = binding._decodeImage(
          handle,
          imageHolder,
          _colorspaceRgb,
          _chromaInterleavedRgba,
          nullptr,
        );
        if (decodeError.code != _errorOk) {
          return const HeifNativeDecode.failed();
        }
        image = imageHolder.value;

        final strideHolder = calloc<Int32>(1);
        try {
          final plane = binding._plane(image, _channelInterleaved, strideHolder);
          if (plane == nullptr) {
            return const HeifNativeDecode.failed();
          }
          final stride = strideHolder.value;
          final rowBytes = width * 4;
          // libheif 的行跨度可能大于 width*4（对齐填充），要按行搬
          final planeBytes = plane.asTypedList(stride * height);
          final pixels = Uint8List(width * height * 4);
          for (var y = 0; y < height; y++) {
            pixels.setRange(
              y * rowBytes,
              (y + 1) * rowBytes,
              planeBytes,
              y * stride,
            );
          }
          return HeifNativeDecode.success(pixels, width, height);
        } finally {
          calloc.free(strideHolder);
        }
      } finally {
        calloc.free(imageHolder);
      }
    } finally {
      calloc.free(handleHolder);
    }
  } finally {
    if (image != nullptr) binding._imageRelease(image);
    binding._contextFree(context);
    calloc.free(input);
  }
}
