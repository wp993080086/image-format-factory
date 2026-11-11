import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixel_forge/core/di/providers.dart';
import 'package:pixel_forge/core/error/app_error.dart';
import 'package:pixel_forge/core/image/crop_selection.dart';
import 'package:pixel_forge/core/image/decode_service.dart';
import 'package:pixel_forge/core/image/encode_service.dart';
import 'package:pixel_forge/core/image/image_format.dart';
import 'package:pixel_forge/core/image/image_header_probe.dart';
import 'package:pixel_forge/core/image/resize_geometry.dart';
import 'package:pixel_forge/core/platform/app_platform.dart';
import 'package:pixel_forge/core/platform/capabilities.dart';
import 'package:pixel_forge/features/editor/editor_controller.dart';
import 'package:pixel_forge/features/editor/editor_state.dart';
import 'package:pixel_forge/services/file/export_service.dart';
import 'package:pixel_forge/services/file/import_service.dart';

/// 可编排返回值的导入服务替身。
class _FakeImportService extends ImportService {
  _FakeImportService(this._result)
    : super(PlatformCapabilities.of(AppTarget.windows));

  final ImportResult? Function() _result;

  @override
  Future<ImportResult?> pickImage() async => _result();
}

/// 解码服务替身：返回固定结果或 null，避免测试依赖真实解码。
class _FakeDecodeService extends DecodeService {
  _FakeDecodeService(this._result);

  final DecodeResult? Function() _result;

  @override
  Future<DecodeResult?> decodePreview(Uint8List bytes) async => _result();
}

/// 编码服务替身，可记录最后一次请求以验证参数透传。
class _FakeEncodeService extends EncodeService {
  _FakeEncodeService(this._result, this.onRequest);

  final EncodeResult? Function() _result;
  final void Function(EncodeRequest)? onRequest;

  @override
  Future<EncodeResult?> encode(EncodeRequest request) async {
    onRequest?.call(request);
    return _result();
  }
}

/// 导出服务替身：返回固定路径，或 null 表示用户取消保存面板。
class _FakeExportService extends ExportService {
  _FakeExportService(this._path);

  final String? _path;

  @override
  Future<ExportResult?> save(ExportRequest request) async =>
      _path == null ? null : ExportResult(savedPath: _path);
}

EncodeResult _stubEncode() => EncodeResult(
  bytes: Uint8List.fromList([0x89, 0x50, 0x4E, 0x47]),
  size: const ImageDimensions(100, 100),
  alphaFlattened: false,
);

DecodeResult _stubDecode() => DecodeResult(
  previewPng: Uint8List.fromList([0x89, 0x50, 0x4E, 0x47]),
  sourceSize: const ImageDimensions(100, 100),
  previewSize: const ImageDimensions(100, 100),
);

ImportResult _validResult({ImageFormat? format = ImageFormat.png}) =>
    ImportResult(
      fileName: 'a.png',
      bytes: Uint8List.fromList([1, 2, 3]),
      format: format,
      isAnimated: false,
      extensionMismatch: false,
    );

/// 构造带 PNG 头、指定宽高的导入结果（用于像素预检）。
ImportResult _pngResult(int w, int h) {
  final bytes = <int>[
    0x89,
    0x50,
    0x4E,
    0x47,
    0x0D,
    0x0A,
    0x1A,
    0x0A,
    0,
    0,
    0,
    13,
    ...'IHDR'.codeUnits,
    (w >> 24) & 0xFF,
    (w >> 16) & 0xFF,
    (w >> 8) & 0xFF,
    w & 0xFF,
    (h >> 24) & 0xFF,
    (h >> 16) & 0xFF,
    (h >> 8) & 0xFF,
    h & 0xFF,
    8,
    6,
    0,
    0,
    0,
  ];
  return ImportResult(
    fileName: 'big.png',
    bytes: Uint8List.fromList(bytes),
    format: ImageFormat.png,
    isAnimated: false,
    extensionMismatch: false,
  );
}

/// 用替身导入/解码服务构建容器并返回控制器。
(ProviderContainer, EditorController) _make(
  ImportResult? Function() result, {
  DecodeResult? Function()? decode,
  EncodeResult? Function()? encode,
  String? savePath = '/tmp/out.png',
  void Function(EncodeRequest)? onEncode,
}) {
  final container = ProviderContainer(
    overrides: [
      importServiceProvider.overrideWithValue(_FakeImportService(result)),
      decodeServiceProvider.overrideWithValue(
        _FakeDecodeService(decode ?? _stubDecode),
      ),
      encodeServiceProvider.overrideWithValue(
        _FakeEncodeService(encode ?? _stubEncode, onEncode),
      ),
      exportServiceProvider.overrideWithValue(_FakeExportService(savePath)),
    ],
  );
  final controller = container.read(editorControllerProvider.notifier);
  return (container, controller);
}

void main() {
  group('EditorState 状态机', () {
    test('初始为空态', () {
      final (container, controller) = _make(() => null);
      addTearDown(container.dispose);
      expect(controller.state.stage, EditorStage.empty);
      expect(controller.state.busy, isFalse);
    });

    test('成功导入 → 可编辑态，并携带导入结果与预览图', () async {
      final (container, controller) = _make(_validResult);
      addTearDown(container.dispose);
      await controller.pickAndLoad();
      expect(controller.state.stage, EditorStage.editable);
      expect(controller.state.imported?.fileName, 'a.png');
      expect(controller.state.decoded, isNotNull);
      expect(controller.state.canEdit, isTrue);
    });

    test('解码失败 → 导入失败态 E-IMG-002', () async {
      final (container, controller) = _make(_validResult, decode: () => null);
      addTearDown(container.dispose);
      await controller.pickAndLoad();
      expect(controller.state.stage, EditorStage.importFailed);
      expect(controller.state.failure?.code, AppErrorCode.corruptedFile);
    });

    test('用户取消（返回 null）→ 回到空态', () async {
      final (container, controller) = _make(() => null);
      addTearDown(container.dispose);
      await controller.pickAndLoad();
      expect(controller.state.stage, EditorStage.empty);
    });

    test('格式无法识别 → 导入失败态 E-IMG-002', () async {
      final (container, controller) = _make(() => _validResult(format: null));
      addTearDown(container.dispose);
      await controller.pickAndLoad();
      expect(controller.state.stage, EditorStage.importFailed);
      expect(controller.state.failure?.code, AppErrorCode.corruptedFile);
      expect(controller.state.failure?.message, '文件已损坏或不是有效图片');
    });

    test('reset 清空状态', () async {
      final (container, controller) = _make(_validResult);
      addTearDown(container.dispose);
      await controller.pickAndLoad();
      controller.reset();
      expect(controller.state.stage, EditorStage.empty);
      expect(controller.state.imported, isNull);
      expect(controller.state.failure, isNull);
    });

    test('像素超限 → 导入失败态 E-IMG-004（Windows 上限 100MP）', () async {
      // 20000 × 20000 = 400MP，超过 Windows 100MP 上限
      final (container, controller) = _make(() => _pngResult(20000, 20000));
      addTearDown(container.dispose);
      await controller.pickAndLoad();
      expect(controller.state.stage, EditorStage.importFailed);
      expect(controller.state.failure?.code, AppErrorCode.pixelLimitExceeded);
      expect(controller.state.failure?.context?['上限'], '100MP');
    });

    test('像素未超限 → 正常进入可编辑态', () async {
      // 4000 × 4000 = 16MP，未超限
      final (container, controller) = _make(() => _pngResult(4000, 4000));
      addTearDown(container.dispose);
      await controller.pickAndLoad();
      expect(controller.state.stage, EditorStage.editable);
    });

    test('「中」态 busy 为真，禁用输入', () {
      const detecting = EditorState(stage: EditorStage.detecting);
      const decoding = EditorState(stage: EditorStage.decoding);
      const exporting = EditorState(stage: EditorStage.exporting);
      expect(detecting.busy, isTrue);
      expect(decoding.busy, isTrue);
      expect(exporting.busy, isTrue);
      expect(const EditorState(stage: EditorStage.editable).busy, isFalse);
    });
  });

  group('导出链路', () {
    test('导出成功 → done 态并记录保存路径', () async {
      final (container, controller) = _make(_validResult);
      addTearDown(container.dispose);
      await controller.pickAndLoad();

      await controller.export(format: ImageFormat.png, quality: 85);

      expect(controller.state.stage, EditorStage.done);
      expect(controller.state.exportedPath, '/tmp/out.png');
      expect(controller.state.failure, isNull);
    });

    test('编码失败 → 导出失败态 E-EXPORT-006', () async {
      final (container, controller) = _make(_validResult, encode: () => null);
      addTearDown(container.dispose);
      await controller.pickAndLoad();

      await controller.export(format: ImageFormat.png, quality: 85);

      expect(controller.state.stage, EditorStage.exportFailed);
      expect(controller.state.failure?.code, AppErrorCode.encodeFailed);
    });

    test('用户取消保存面板 → 回到可编辑态，不算失败', () async {
      final (container, controller) = _make(_validResult, savePath: null);
      addTearDown(container.dispose);
      await controller.pickAndLoad();

      await controller.export(format: ImageFormat.png, quality: 85);

      expect(controller.state.stage, EditorStage.editable);
      expect(controller.state.failure, isNull);
    });

    test('未导入图片时导出无动作', () async {
      final (container, controller) = _make(() => null);
      addTearDown(container.dispose);

      await controller.export(format: ImageFormat.png, quality: 85);

      expect(controller.state.stage, EditorStage.empty);
    });

    test('continueEditing 从 done 回到可编辑', () async {
      final (container, controller) = _make(_validResult);
      addTearDown(container.dispose);
      await controller.pickAndLoad();
      await controller.export(format: ImageFormat.png, quality: 85);
      expect(controller.state.stage, EditorStage.done);

      controller.continueEditing();

      expect(controller.state.stage, EditorStage.editable);
    });
  });

  group('拖拽导入', () {
    test('loadImport 与选图走同一套探测与解码流程', () async {
      final (container, controller) = _make(() => null);
      addTearDown(container.dispose);

      await controller.loadImport(_validResult());

      expect(controller.state.stage, EditorStage.editable);
      expect(controller.state.imported?.fileName, 'a.png');
      expect(controller.state.crop, isNotNull);
    });

    test('非图片内容 → E-IMG-002', () async {
      final (container, controller) = _make(() => null);
      addTearDown(container.dispose);

      await controller.loadImport(
        ImportResult(
          fileName: 'a.txt',
          bytes: Uint8List.fromList([1, 2, 3, 4]),
          format: null,
          isAnimated: false,
          extensionMismatch: false,
        ),
      );

      expect(controller.state.stage, EditorStage.importFailed);
      expect(controller.state.failure?.code, AppErrorCode.corruptedFile);
    });

    test('超大图片走同一套像素预检', () async {
      final (container, controller) = _make(() => null);
      addTearDown(container.dispose);

      // 20000×20000 = 4 亿像素，超过 Windows 的 1 亿上限
      await controller.loadImport(_pngResult(20000, 20000));

      expect(controller.state.failure?.code, AppErrorCode.pixelLimitExceeded);
    });
  });

  group('尺寸与比例', () {
    test('导入后没有生效中的尺寸变换', () async {
      final (container, controller) = _make(_validResult);
      addTearDown(container.dispose);
      await controller.pickAndLoad();

      expect(controller.state.resize, isNull);
      expect(controller.state.hasResize, isFalse);
    });

    test('updateResize 写入目标尺寸并标记生效', () async {
      final (container, controller) = _make(_validResult);
      addTearDown(container.dispose);
      await controller.pickAndLoad();

      controller.updateResize(width: 50, height: 40);

      expect(controller.state.resize?.width, 50);
      expect(controller.state.resize?.height, 40);
      expect(controller.state.hasResize, isTrue);
    });

    test('超过 4 倍放大被钳制并带回原因', () async {
      final (container, controller) = _make(_validResult);
      addTearDown(container.dispose);
      await controller.pickAndLoad();

      final clamp = controller.updateResize(width: 800, height: 400);

      // 源 100×100，单边上限 400
      expect(clamp?.edgeLimited, isTrue);
      expect(controller.state.resize?.width, 400);
      expect(controller.state.resize?.height, 400);
    });

    test('目标尺寸等于原图时不算生效', () async {
      final (container, controller) = _make(_validResult);
      addTearDown(container.dispose);
      await controller.pickAndLoad();

      controller.updateResize(width: 100, height: 100);

      expect(controller.state.resize, isNotNull);
      expect(controller.state.hasResize, isFalse);
    });

    test('resetResize 清空变换', () async {
      final (container, controller) = _make(_validResult);
      addTearDown(container.dispose);
      await controller.pickAndLoad();
      controller.updateResize(width: 50, height: 50);

      controller.resetResize();

      expect(controller.state.resize, isNull);
      expect(controller.state.hasResize, isFalse);
    });

    test('重新导入后尺寸变换被重置', () async {
      final (container, controller) = _make(_validResult);
      addTearDown(container.dispose);
      await controller.pickAndLoad();
      controller.updateResize(width: 50, height: 50);

      await controller.pickAndLoad();

      expect(controller.state.resize, isNull);
    });

    test('导出时携带尺寸变换参数', () async {
      EncodeRequest? captured;
      final (container, controller) = _make(
        _validResult,
        onEncode: (request) => captured = request,
      );
      addTearDown(container.dispose);
      await controller.pickAndLoad();
      controller.updateResize(
        width: 50,
        height: 50,
        mode: ResizeMode.contain,
        backgroundArgb: 0xFFFFFFFF,
      );

      await controller.export(format: ImageFormat.png, quality: 85);

      expect(captured?.resize?.width, 50);
      expect(captured?.resize?.mode, ResizeMode.contain);
      expect(captured?.resize?.backgroundArgb, 0xFFFFFFFF);
    });

    test('未调尺寸时导出不带 resize 参数', () async {
      EncodeRequest? captured;
      final (container, controller) = _make(
        _validResult,
        onEncode: (request) => captured = request,
      );
      addTearDown(container.dispose);
      await controller.pickAndLoad();

      await controller.export(format: ImageFormat.png, quality: 85);

      expect(captured?.resize, isNull);
    });
  });

  group('裁剪选区', () {
    test('导入后默认全选整图，且不算生效中的裁剪', () async {
      final (container, controller) = _make(_validResult);
      addTearDown(container.dispose);
      await controller.pickAndLoad();

      final crop = controller.state.crop!;
      expect(crop.left, 0);
      expect(crop.top, 0);
      expect(crop.width, 100);
      expect(crop.height, 100);
      expect(controller.state.hasCrop, isFalse);
    });

    test('缩小选区后 hasCrop 为真', () async {
      final (container, controller) = _make(_validResult);
      addTearDown(container.dispose);
      await controller.pickAndLoad();

      controller.updateCrop(
        const CropSelection(left: 10, top: 10, width: 50, height: 40),
      );

      expect(controller.state.hasCrop, isTrue);
      expect(controller.state.crop?.width, 50);
    });

    test('圆形即使覆盖全图也算生效（要抹掉圆外像素）', () async {
      final (container, controller) = _make(_validResult);
      addTearDown(container.dispose);
      await controller.pickAndLoad();

      controller.updateCropShape(CropShape.circle);

      expect(controller.state.hasCrop, isTrue);
    });

    test('导出时把整数裁剪区传给编码服务', () async {
      EncodeRequest? captured;
      final (container, controller) = _make(
        _validResult,
        onEncode: (request) => captured = request,
      );
      addTearDown(container.dispose);
      await controller.pickAndLoad();
      controller.updateCrop(
        const CropSelection(left: 10.4, top: 20.6, width: 50, height: 40),
      );

      await controller.export(format: ImageFormat.png, quality: 85);

      expect(captured?.crop?.x, 10);
      expect(captured?.crop?.y, 21);
      expect(captured?.crop?.width, 50);
      expect(captured?.cropCircle, isFalse);
    });

    test('全图选区导出时不传裁剪区（省一次整图拷贝）', () async {
      EncodeRequest? captured;
      final (container, controller) = _make(
        _validResult,
        onEncode: (request) => captured = request,
      );
      addTearDown(container.dispose);
      await controller.pickAndLoad();

      await controller.export(format: ImageFormat.png, quality: 85);

      expect(captured?.crop, isNull);
      expect(captured?.cropCircle, isFalse);
    });

    test('圆形选区导出时带 cropCircle 标记', () async {
      EncodeRequest? captured;
      final (container, controller) = _make(
        _validResult,
        onEncode: (request) => captured = request,
      );
      addTearDown(container.dispose);
      await controller.pickAndLoad();
      controller.updateCropShape(CropShape.circle);

      await controller.export(format: ImageFormat.png, quality: 85);

      expect(captured?.cropCircle, isTrue);
      expect(captured?.crop, isNotNull);
    });

    test('切到圆形时非法比例自动回落到 1:1', () async {
      final (container, controller) = _make(_validResult);
      addTearDown(container.dispose);
      await controller.pickAndLoad();

      controller.updateCropAspect(CropAspect.ratio16x9);
      expect(controller.state.cropAspect, CropAspect.ratio16x9);

      controller.updateCropShape(CropShape.circle);
      expect(controller.state.cropAspect, CropAspect.square);
    });

    test('圆形下切换非法比例被忽略', () async {
      final (container, controller) = _make(_validResult);
      addTearDown(container.dispose);
      await controller.pickAndLoad();
      controller.updateCropShape(CropShape.circle);

      controller.updateCropAspect(CropAspect.ratio4x3);

      expect(controller.state.cropAspect, CropAspect.square);
    });

    test('resetCrop 恢复整图选区', () async {
      final (container, controller) = _make(_validResult);
      addTearDown(container.dispose);
      await controller.pickAndLoad();
      controller.updateCrop(
        const CropSelection(left: 10, top: 10, width: 50, height: 40),
      );

      controller.resetCrop();

      expect(controller.state.crop?.width, 100);
      expect(controller.state.crop?.height, 100);
      expect(controller.state.hasCrop, isFalse);
    });

    test('重新导入后选区重置为整图', () async {
      final (container, controller) = _make(_validResult);
      addTearDown(container.dispose);
      await controller.pickAndLoad();
      controller.updateCrop(
        const CropSelection(left: 10, top: 10, width: 50, height: 40),
      );

      await controller.pickAndLoad();

      expect(controller.state.crop?.width, 100);
      expect(controller.state.hasCrop, isFalse);
    });
  });
}
