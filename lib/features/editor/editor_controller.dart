import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/providers.dart';
import '../../core/error/app_error.dart';
import '../../core/error/export_error_mapper.dart';
import '../../core/image/crop_selection.dart';
import '../../core/image/annotation.dart';
import '../../core/image/decode_policy.dart';
import '../../core/image/encode_service.dart';
import '../../core/image/image_format.dart';
import '../../core/image/image_header_probe.dart';
import '../../core/image/resize_geometry.dart';
import '../../core/log/app_logger.dart';
import '../../services/file/export_service.dart';
import '../../services/file/import_service.dart';
import '../../services/image/avif_codec.dart';
import '../../services/image/heif_decoder.dart';
import '../editor/editor_state.dart';

/// 功能页状态机控制器（PRD 九.5）。
///
/// 所有功能页（裁切 / 缩放 / 导出）共用同一状态；
/// 状态由本控制器持有，页面仅按 [EditorState.stage] 分态渲染。
class EditorController extends Notifier<EditorState> {
  static const _tag = 'EditorController';

  @override
  EditorState build() => const EditorState();

  ImportService get _importService => ref.read(importServiceProvider);

  /// 选图 → 探测 → 解码 → 可编辑。
  Future<void> pickAndLoad() async {
    if (state.busy) return;
    state = state.copyWith(
      stage: EditorStage.detecting,
      phase: ProgressPhase.readingFile,
      clearFailure: true,
    );
    try {
      final result = await _importService.pickImage();
      if (result == null) {
        // 用户取消：回到空态
        state = state.copyWith(stage: EditorStage.empty);
        return;
      }
      await _process(result);
    } catch (e, st) {
      AppLogger.error('导入失败', name: _tag, error: e, stackTrace: st);
      _fail(AppErrorCode.corruptedFile, error: e, stackTrace: st);
    }
  }

  /// 直接加载外部读入的导入结果（拖拽导入，PRD 六.1）。
  ///
  /// 与 [pickAndLoad] 共用同一套探测、像素预检与解码流程。
  Future<void> loadImport(ImportResult result) async {
    if (state.busy) return;
    state = state.copyWith(
      stage: EditorStage.detecting,
      phase: ProgressPhase.readingFile,
      clearFailure: true,
    );
    try {
      await _process(result);
    } catch (e, st) {
      AppLogger.error('导入失败', name: _tag, error: e, stackTrace: st);
      _fail(AppErrorCode.corruptedFile, error: e, stackTrace: st);
    }
  }

  /// 探测校验 → 像素预检 → 解码预览 → 进入可编辑态。
  Future<void> _process(ImportResult result) async {
    // 内容与扩展名均无法识别 → E-IMG-002
    final format = result.format;
    if (format == null) {
      _fail(AppErrorCode.corruptedFile);
      return;
    }
    // 能力矩阵之外的格式一律拒绝：拖拽导入可绕过选择器的扩展名过滤。
    // 典型的是 SVG——文件头能探测出来，但当前没有光栅化能力（ADR-004 的
    // flutter_svg 方案尚未接入）；TIFF/TGA/PPM 则按附录 #8 移出 MVP。
    // 报「不支持该格式」而不是「文件已损坏」，否则用户会以为自己的图坏了。
    if (!ref.read(capabilitiesProvider).canImport(format)) {
      _fail(AppErrorCode.unsupportedFormat);
      return;
    }
    // HEIF 家族（苹果 HEIC / 华为 HEIF / AVIF）纯 Dart 解不了，先借平台能力转 PNG。
    // 放在像素预检之前：平台侧先读尺寸判定上限，超限直接返回而不分配位图，
    // 避免 OOM 杀进程。AVIF 的 Windows CLI 也用 --size-limit 做了同等前置拦截。
    var bytes = result.bytes;
    if (format == ImageFormat.heic) {
      final heif = await HeifDecoder.decode(
        bytes,
        maxPixels: ref.read(capabilitiesProvider).maxPixels,
      );
      if (!heif.isSuccess) {
        _fail(switch (heif.error) {
          HeifDecodeError.pixelLimit => AppErrorCode.pixelLimitExceeded,
          HeifDecodeError.unsupportedPlatform => AppErrorCode.unsupportedFormat,
          _ => AppErrorCode.corruptedFile,
        });
        return;
      }
      bytes = heif.png!;
    } else if (format == ImageFormat.avif) {
      final avif = await AvifCodec.decode(
        bytes,
        maxPixels: ref.read(capabilitiesProvider).maxPixels,
      );
      if (!avif.isSuccess) {
        _fail(switch (avif.error!) {
          AvifDecodeError.pixelLimit => AppErrorCode.pixelLimitExceeded,
          AvifDecodeError.unsupportedPlatform => AppErrorCode.unsupportedFormat,
          _ => AppErrorCode.corruptedFile,
        });
        return;
      }
      bytes = avif.png!;
    }
    // 像素预检（PRD 九.3（2））：解码前仅读文件头取宽高，超限直接拒绝。
    // Dart 的 OOM 是进程级 crash、catch 不住，故必须在此前置拦截。
    final dims = ImageHeaderProbe.probe(bytes, format);
    if (dims != null) {
      final maxPixels = ref.read(capabilitiesProvider).maxPixels;
      if (DecodePolicy.exceedsLimit(dims, maxPixels)) {
        _fail(
          AppErrorCode.pixelLimitExceeded,
          context: {
            '像素': '${(dims.pixels / 1000000).toStringAsFixed(1)}MP',
            '上限': '${maxPixels ~/ 1000000}MP',
          },
        );
        return;
      }
    }
    // 解码 + 生成预览图（PRD 九.3）：在子 Isolate 执行，UI 不阻塞。
    // HEIF 已在上面转成 PNG，这里拿到的已是通用格式字节。
    state = state.copyWith(stage: EditorStage.decoding);
    final decoded = await ref
        .read(decodeServiceProvider)
        .decodePreview(bytes);
    if (decoded == null) {
      // 头部可识别但解码失败 → 文件损坏
      _fail(AppErrorCode.corruptedFile);
      return;
    }
    state = state.copyWith(
      stage: EditorStage.editable,
      imported: result,
      decoded: decoded,
      crop: CropSelection.full(decoded.sourceSize),
      cropShape: CropShape.rectangle,
      cropAspect: CropAspect.free,
      clearResize: true,
      clearBlur: true,
      clearFailure: true,
    );
  }

  /// 重新选择（错误卡片出口）。
  void reset() {
    _undoStack.clear();
    _redoStack.clear();
    state = const EditorState();
  }

  // ---- 标注编辑 + 撤销/重做 ------------------------------------------------

  /// 撤销栈：每项是一份提交前的完整标注列表快照。
  final List<List<Annotation>> _undoStack = [];
  final List<List<Annotation>> _redoStack = [];
  static const _maxHistory = 50;

  void _pushHistory() {
    _undoStack.add(List<Annotation>.from(state.annotations));
    if (_undoStack.length > _maxHistory) _undoStack.removeAt(0);
    _redoStack.clear();
  }

  /// 新增一条标注（一次拖拽结束提交一次）。
  void addAnnotation(Annotation a) {
    if (!state.canEdit) return;
    _pushHistory();
    final index = state.annotations.length;
    state = state.copyWith(
      annotations: [...state.annotations, a],
      selectedAnnotation: index,
    );
  }

  /// 是否处于一次连续编辑手势中（拖手柄 / 拖滑块）。
  /// 期间 [updateAnnotation] 不再逐帧压撤销栈，手势结束只留一条快照。
  bool _inAnnotationGesture = false;

  /// 连续编辑开始：压一次历史快照。
  void beginAnnotationGesture() {
    if (_inAnnotationGesture) return;
    _inAnnotationGesture = true;
    _pushHistory();
  }

  /// 连续编辑结束。
  void endAnnotationGesture() => _inAnnotationGesture = false;

  /// 替换指定索引的标注（手柄调整提交）。
  void updateAnnotation(int index, Annotation a) {
    if (!state.canEdit || index < 0 || index >= state.annotations.length) return;
    if (!_inAnnotationGesture) _pushHistory();
    final next = List<Annotation>.from(state.annotations)..[index] = a;
    state = state.copyWith(annotations: next);
  }

  /// 删除指定标注。
  void removeAnnotation(int index) {
    if (!state.canEdit || index < 0 || index >= state.annotations.length) return;
    _pushHistory();
    final next = List<Annotation>.from(state.annotations)..removeAt(index);
    state = state.copyWith(
      annotations: next,
      clearSelected: true,
    );
  }

  void selectAnnotation(int? index) =>
      state = state.copyWith(
        selectedAnnotation: index,
        clearSelected: index == null,
      );

  void clearAnnotations() {
    if (state.annotations.isEmpty) return;
    _pushHistory();
    state = state.copyWith(annotations: const [], clearSelected: true);
  }

  /// 更新整图模糊强度（0–100）；跨页保留，导出时生效（v0.6）。
  void setBlur(int intensity) {
    if (!state.canEdit) return;
    state = state.copyWith(blur: intensity.clamp(0, 100));
  }

  bool get canUndo => _undoStack.isNotEmpty;
  bool get canRedo => _redoStack.isNotEmpty;

  void undo() {
    if (_undoStack.isEmpty) return;
    _redoStack.add(List<Annotation>.from(state.annotations));
    state = state.copyWith(
      annotations: _undoStack.removeLast(),
      clearSelected: true,
    );
  }

  void redo() {
    if (_redoStack.isEmpty) return;
    _undoStack.add(List<Annotation>.from(state.annotations));
    state = state.copyWith(
      annotations: _redoStack.removeLast(),
      clearSelected: true,
    );
  }

  /// 更新选区：拖拽、手柄、目标尺寸输入共用同一出口。
  void updateCrop(CropSelection selection) {
    if (!state.canEdit) return;
    state = state.copyWith(crop: selection);
    _reclampResizeAfterCrop();
  }

  /// 裁剪改变基准后，把已设的目标尺寸按新上限重新钳制。
  ///
  /// 不重算会留下「按旧基准合法、按新基准超限」的目标：先设 16000×12000
  /// 再把选区裁到 300×300，导出时至多只能放大到 1200×1200，超出的部分
  /// 既浪费内存又让「目标尺寸」名不副实。
  void _reclampResizeAfterCrop() {
    final target = state.resize;
    if (target == null) return;
    final clamp = clampResizeTarget(
      state.resizeBase,
      target.width,
      target.height,
    );
    if (clamp.width == target.width && clamp.height == target.height) return;
    state = state.copyWith(
      resize: target.copyWith(width: clamp.width, height: clamp.height),
    );
  }

  /// 切换选区形状。
  ///
  /// 切入圆形时规范化为 1:1：圆形本质是正方形选区加遮罩，若状态里留着
  /// 「自由」会让 UI 显示自由比例、实际却锁死 1:1，语义自相矛盾。
  void updateCropShape(CropShape shape) {
    final size = state.decoded?.sourceSize;
    final selection = state.crop;
    if (!state.canEdit || size == null || selection == null) return;
    final aspect = shape == CropShape.circle
        ? CropAspect.square
        : (state.cropAspect.allowedFor(shape)
              ? state.cropAspect
              : CropAspect.square);
    state = state.copyWith(
      cropShape: shape,
      cropAspect: aspect,
      crop: selection.withAspect(aspect, shape, size),
    );
    _reclampResizeAfterCrop();
  }

  /// 切换比例预设；非法组合（圆形 + 非 1:1）直接忽略，UI 侧应已置灰。
  void updateCropAspect(CropAspect aspect) {
    final size = state.decoded?.sourceSize;
    final selection = state.crop;
    if (!state.canEdit || size == null || selection == null) return;
    if (!aspect.allowedFor(state.cropShape)) return;
    state = state.copyWith(
      cropAspect: aspect,
      crop: selection.withAspect(aspect, state.cropShape, size),
    );
    _reclampResizeAfterCrop();
  }

  /// 按目标像素尺寸重建选区（PRD 二.3：原图像素，超限钳制，以当前中心为锚点）。
  void setCropTargetSize(int width, int height) {
    final size = state.decoded?.sourceSize;
    final selection = state.crop;
    if (!state.canEdit || size == null || selection == null) return;
    state = state.copyWith(
      crop: selection.withTargetSize(width, height, size, state.cropShape),
    );
    _reclampResizeAfterCrop();
  }

  /// 选区还原为整图。
  void resetCrop() {
    final size = state.decoded?.sourceSize;
    if (!state.canEdit || size == null) return;
    state = state.copyWith(crop: CropSelection.full(size));
    _reclampResizeAfterCrop();
  }

  /// 更新尺寸与比例变换参数（PRD 三章）。
  ///
  /// 宽高按 [clampResizeTarget] 的双上限钳制后写入，返回值供 UI 提示
  /// 「已限制为 …」；未导入或非可编辑态时返回 null。
  ResizeClamp? updateResize({
    int? width,
    int? height,
    ResizeMode? mode,
    int? backgroundArgb,
  }) {
    final base = state.resizeBase;
    if (!state.canEdit || base.width <= 0) return null;
    final current =
        state.resize ?? ResizeTarget(width: base.width, height: base.height);
    final clamp = clampResizeTarget(
      base,
      width ?? current.width,
      height ?? current.height,
    );
    state = state.copyWith(
      resize: current.copyWith(
        width: clamp.width,
        height: clamp.height,
        mode: mode,
        backgroundArgb: backgroundArgb,
      ),
    );
    return clamp;
  }

  /// 还原原始尺寸：导出时按原图输出。
  void resetResize() {
    if (!state.canEdit) return;
    state = state.copyWith(clearResize: true);
  }

  /// 导出：从源字节流二次解码全图 → 编码 → 唤起保存面板写入（PRD 九.3 / 六.2）。
  ///
  /// [format] 须在 `EncodeService.exportableFormats` 内；[quality] 仅对 JPEG 生效；
  /// [icoSizes] 仅对 ICO 生效，为空时取全部可生成尺寸；
  /// [jpegChroma] / [pngLevel] / [pngPalette] 分别只对 JPEG / PNG 生效；
  /// [exportAnimation] 仅对 GIF + 动图源生效，逐帧保留帧序、延时与循环。
  Future<void> export({
    required ImageFormat format,
    required int quality,
    List<int> icoSizes = const [],
    JpegChromaOption jpegChroma = JpegChromaOption.yuv420,
    int pngLevel = 6,
    bool pngPalette = false,
    bool exportAnimation = false,
  }) async {
    final imported = state.imported;
    if (state.busy || !state.canEdit || imported == null) return;

    state = state.copyWith(
      stage: EditorStage.exporting,
      phase: ProgressPhase.processing,
      clearFailure: true,
    );
    // 全图矩形选区等价于不裁剪，省掉一次整图拷贝（PRD 二章注）
    final cropArea = state.hasCrop ? state.crop?.toArea() : null;
    final cropCircle = state.hasCrop && state.cropShape == CropShape.circle;

    // 标注从原图坐标映射到裁剪+缩放后的输出坐标（PRD 一.7 合成顺序）
    final sourceSize = state.decoded!.sourceSize;
    final baseW = cropArea?.width ?? sourceSize.width;
    final baseH = cropArea?.height ?? sourceSize.height;
    final resizeTarget = state.hasResize ? state.resize : null;
    final annotations = transformAnnotations(
      state.annotations,
      cropX: cropArea?.x ?? 0,
      cropY: cropArea?.y ?? 0,
      cropW: baseW,
      cropH: baseH,
      resize: resizeTarget,
    );
    // HEIF 源在导入时已转过一次给预览；这里要的是全分辨率字节，得再转一次。
    // 不在导入时缓存全图 PNG：移动端常驻一份 20MB+ 的中间图代价过高。
    var sourceBytes = imported.bytes;
    if (imported.format == ImageFormat.heic) {
      final heif = await HeifDecoder.decode(
        sourceBytes,
        maxPixels: ref.read(capabilitiesProvider).maxPixels,
      );
      if (!heif.isSuccess) {
        _fail(AppErrorCode.encodeFailed);
        return;
      }
      sourceBytes = heif.png!;
    }
    try {
      final encoded = await ref
          .read(encodeServiceProvider)
          .encode(
            EncodeRequest(
              sourceBytes: sourceBytes,
              format: format,
              quality: quality,
              icoSizes: icoSizes,
              crop: cropArea,
              cropCircle: cropCircle,
              resize: resizeTarget,
              jpegChroma: jpegChroma,
              pngLevel: pngLevel,
              pngPalette: pngPalette,
              exportAnimation: exportAnimation && imported.isAnimated,
              annotations: annotations,
              blur: state.blur,
            ),
          );
      if (encoded == null) {
        _fail(AppErrorCode.encodeFailed);
        return;
      }

      state = state.copyWith(phase: ProgressPhase.writing);
      final result = await ref
          .read(exportServiceProvider)
          .save(
            ExportRequest(
              suggestedName: buildExportFileName(
                sourceFileName: imported.fileName,
                format: format,
                quality: quality,
                width: encoded.size.width,
                height: encoded.size.height,
              ),
              bytes: encoded.bytes,
              format: format,
            ),
          );
      if (result == null) {
        // 用户取消保存面板：回到可编辑态，不算失败
        state = state.copyWith(stage: EditorStage.editable);
        return;
      }

      state = state.copyWith(
        stage: EditorStage.done,
        exportedPath: result.savedPath,
      );
    } catch (e, st) {
      // 按异常类型归到 PRD 九.2 的细分错误码（磁盘满 / 只读 / 被占用 / 路径非法）。
      // 归类不出来的才落到 E-EXPORT-006，那句话才真的成立。
      AppLogger.error('导出失败', name: _tag, error: e, stackTrace: st);
      _fail(mapExportError(e), error: e, stackTrace: st);
    }
  }

  /// 完成态回到可编辑（PRD 九.5「继续编辑」）。
  void continueEditing() => state = state.copyWith(stage: EditorStage.editable);

  void _fail(
    AppErrorCode code, {
    Object? error,
    StackTrace? stackTrace,
    Map<String, String>? context,
  }) {
    final failure = AppFailure(
      code,
      context: context,
      error: error,
      stackTrace: stackTrace,
    );
    AppLogger.warn('${code.code}: ${failure.message}', name: _tag);
    state = state.copyWith(
      stage: code.isExportError
          ? EditorStage.exportFailed
          : EditorStage.importFailed,
      failure: failure,
    );
  }
}

/// 功能页状态机（PRD 九.5），裁切/缩放/导出三页共用。
final editorControllerProvider =
    NotifierProvider<EditorController, EditorState>(EditorController.new);
