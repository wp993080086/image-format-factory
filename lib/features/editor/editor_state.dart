import '../../services/file/import_service.dart';
import '../../core/error/app_error.dart';
import '../../core/image/crop_selection.dart';
import '../../core/image/decode_service.dart';
import '../../core/image/image_header_probe.dart';
import '../../core/image/resize_geometry.dart';

/// 功能页共用状态机的阶段（对应 PRD 九.5）。
enum EditorStage {
  /// 空态：未选图。
  empty,

  /// 探测中：读取文件头、判定格式。
  detecting,

  /// 解码中：解码 + 生成预览图（进度：读文件/解码/生成预览）。
  decoding,

  /// 可编辑：预览图 + 参数面板 + 实时体积预估。
  editable,

  /// 导出中：重新解码/处理/编码/写入。
  exporting,

  /// 完成态。
  done,

  /// 导入失败态（E-IMG-0xx）。
  importFailed,

  /// 导出失败态（E-EXPORT-0xx）。
  exportFailed,
}

/// 进度阶段文案（PRD 九.3 要求进度条覆盖三段）。
enum ProgressPhase {
  readingFile('载入原图'),
  decoding('载入原图'),
  processing('处理中'),
  writing('写入文件');

  const ProgressPhase(this.label);

  final String label;
}

/// 功能页状态机的不可变状态。
class EditorState {
  const EditorState({
    this.stage = EditorStage.empty,
    this.imported,
    this.decoded,
    this.failure,
    this.phase = ProgressPhase.readingFile,
    this.progress = 0,
    this.exportedPath,
    this.crop,
    this.cropShape = CropShape.rectangle,
    this.cropAspect = CropAspect.free,
    this.resize,
  });

  final EditorStage stage;

  /// 导入结果（探测成功后有值）。
  final ImportResult? imported;

  /// 解码结果（含预览图与原图尺寸，解码成功后进入可编辑态时有值）。
  final DecodeResult? decoded;

  /// 失败信息（importFailed / exportFailed 时有值）。
  final AppFailure? failure;

  final ProgressPhase phase;

  /// 进度 0.0–1.0。
  final double progress;

  /// 导出成功后的本地路径（done 态有值；Web 端下载通道为 null）。
  final String? exportedPath;

  /// 裁剪选区（原图坐标系）。null 表示未设置，导出时视为不裁剪。
  final CropSelection? crop;

  /// 裁剪形状，跨页保留（导出时需要据此决定是否套圆形遮罩）。
  final CropShape cropShape;

  /// 比例预设，跨页保留以便返回裁剪页时恢复。
  final CropAspect cropAspect;

  /// 尺寸与比例变换的目标；null 表示保持原尺寸（PRD 三章）。
  final ResizeTarget? resize;

  /// 缩放的基准尺寸：裁剪生效后是选区落地尺寸，否则是原图尺寸。
  ///
  /// 导出管线是「先裁后缩」，缩放作用在裁剪结果上，所以锁定比例、默认目标
  /// 与 4 倍放大上限都必须以此为准。若仍按原图算，裁成 1:1 后锁定会拿到
  /// 原图的 4:3，输入宽 500 得到 500×375，导出时再把方形内容拉变形。
  ImageDimensions get resizeBase {
    final size = decoded?.sourceSize;
    if (size == null) return const ImageDimensions(0, 0);
    final selection = crop;
    if (selection == null || !hasCrop) return size;
    final area = selection.toArea();
    return ImageDimensions(area.width, area.height);
  }

  /// 是否有生效中的尺寸变换（目标尺寸与缩放基准不同）。
  bool get hasResize {
    final target = resize;
    if (target == null || decoded == null) return false;
    return target.differsFrom(resizeBase);
  }

  /// 是否有生效中的裁剪（非全图矩形）。
  ///
  /// 圆形即使覆盖全图也算生效——圆外像素要被抹成透明。
  bool get hasCrop {
    final selection = crop;
    final size = decoded?.sourceSize;
    if (selection == null || size == null) return false;
    if (cropShape == CropShape.circle) return true;
    return !selection.covers(size);
  }

  /// 是否处于「中」态——此态禁用输入、不允许返回上一页（PRD 九.5）。
  bool get busy =>
      stage == EditorStage.detecting ||
      stage == EditorStage.decoding ||
      stage == EditorStage.exporting;

  /// 是否可编辑。
  bool get canEdit => stage == EditorStage.editable;

  EditorState copyWith({
    EditorStage? stage,
    ImportResult? imported,
    DecodeResult? decoded,
    AppFailure? failure,
    ProgressPhase? phase,
    double? progress,
    String? exportedPath,
    CropSelection? crop,
    CropShape? cropShape,
    CropAspect? cropAspect,
    ResizeTarget? resize,
    bool clearFailure = false,
    bool clearCrop = false,
    bool clearResize = false,
  }) {
    return EditorState(
      stage: stage ?? this.stage,
      imported: imported ?? this.imported,
      decoded: decoded ?? this.decoded,
      failure: clearFailure ? null : (failure ?? this.failure),
      phase: phase ?? this.phase,
      progress: progress ?? this.progress,
      exportedPath: exportedPath ?? this.exportedPath,
      crop: clearCrop ? null : (crop ?? this.crop),
      cropShape: cropShape ?? this.cropShape,
      cropAspect: cropAspect ?? this.cropAspect,
      resize: clearResize ? null : (resize ?? this.resize),
    );
  }
}
