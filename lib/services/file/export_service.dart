import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter_file_dialog/flutter_file_dialog.dart';

import '../../core/image/image_format.dart';
import '../../core/platform/app_platform.dart';
import 'file_io.dart';

/// 导出请求。
class ExportRequest {
  const ExportRequest({
    required this.suggestedName,
    required this.bytes,
    required this.format,
  });

  final String suggestedName;
  final Uint8List bytes;
  final ImageFormat format;
}

/// 导出结果。
class ExportResult {
  const ExportResult({required this.savedPath});

  /// 保存后的本地路径；Web 端（下载通道）为 null。
  final String? savedPath;
}

/// 生成导出文件名（PRD 九.4）：`{原名}_{标识}.{ext}`。
///
/// JPEG 以质量为标识（`q85`），ICO 无单一宽高故固定 `icon`，
/// 其余格式以尺寸为标识（`2400x1600`）。
String buildExportFileName({
  required String sourceFileName,
  required ImageFormat format,
  required int quality,
  required int width,
  required int height,
}) {
  final dot = sourceFileName.lastIndexOf('.');
  final base = dot > 0 ? sourceFileName.substring(0, dot) : sourceFileName;
  final tag = switch (format) {
    ImageFormat.jpeg => 'q$quality',
    ImageFormat.ico => 'icon',
    _ => '${width}x$height',
  };
  return '${base}_$tag.${format.extensions.first}';
}

/// 保存位置的展示文案（PRD 九.4）。
///
/// Android 的 SAF 只回 `content://` URI，拿不到文件系统路径；把
/// `content://media/external/images/media/42` 这种串摆给用户没有意义，
/// 统一说「你选择的位置」。桌面端仍显示真实路径。
String displaySavedPath(String? path, {String fallback = '你选择的位置'}) {
  if (path == null) return fallback;
  if (path.startsWith('content://')) return fallback;
  return path;
}

/// 图片导出服务：封装各端保存差异（PRD 六.2）。
class ExportService {
  const ExportService({this.target});

  /// 目标端。测试可注入；运行时取 [AppPlatform.current]。
  ///
  /// 之所以不直接读静态值，是因为组件的平台探测在本机永远是 Windows，
  /// 移动端分支（SAF）否则一行都跑不到。
  final AppTarget? target;

  AppTarget get _resolvedTarget => target ?? AppPlatform.current;

  /// 唤起系统保存面板并写入文件；用户取消时返回 null。
  Future<ExportResult?> save(ExportRequest request) async {
    return saveAs(
      suggestedName: request.suggestedName,
      bytes: request.bytes,
      extensions: request.format.extensions,
      label: request.format.displayName,
      mimeTypes: [request.format.mimeType],
    );
  }

  /// 保存任意文件（如诊断日志），与图片导出共用同一套保存通道。
  ///
  /// 单独开这个入口而不是给 [ExportRequest] 加字段：图片导出需要
  /// [ImageFormat] 决定扩展名与类型分组，文本文件没有对应格式枚举，
  /// 硬塞会让 `ImageFormat` 承担它不该承担的语义。
  Future<ExportResult?> saveAs({
    required String suggestedName,
    required Uint8List bytes,
    required List<String> extensions,
    required String label,
    List<String>? mimeTypes,
  }) async {
    // Android 没有「另存为」对话框：file_selector 的 getSaveLocation 在移动端
    // 会走默认实现直接 UnimplementedError（源码级核对见 ADR-007），
    // 因此改走 SAF 的 ACTION_CREATE_DOCUMENT。
    if (_resolvedTarget == AppTarget.android) {
      return _saveWithSystemDialog(
        suggestedName: suggestedName,
        bytes: bytes,
        mimeTypes: mimeTypes,
      );
    }
    // 鸿蒙没有 SAF 等价物，ADR-007 给的是 share_plus 通道，M3 才接。
    // 在这里明确拦一下，别让用户看到 file_selector 那句平台内部异常。
    if (_resolvedTarget == AppTarget.harmony) {
      throw UnsupportedError('鸿蒙端导出通道尚未接入（ADR-007，M3 落地）');
    }
    return _saveWithSaveDialog(
      suggestedName: suggestedName,
      bytes: bytes,
      extensions: extensions,
      label: label,
    );
  }

  /// 桌面端：系统「另存为」对话框 + 自行写盘。
  Future<ExportResult?> _saveWithSaveDialog({
    required String suggestedName,
    required Uint8List bytes,
    required List<String> extensions,
    required String label,
  }) async {
    final group = XTypeGroup(label: label, extensions: extensions);
    final location = await getSaveLocation(
      suggestedName: suggestedName,
      acceptedTypeGroups: [group],
    );
    if (location == null) return null;

    await writeBytesToFile(location.path, bytes);
    return ExportResult(savedPath: location.path);
  }

  /// Android：SAF `ACTION_CREATE_DOCUMENT`，由系统把字节写进用户选定的位置。
  ///
  /// 返回的 `savedPath` 是 `content://` URI 而非文件系统路径——SAF 本来就不
  /// 暴露真实路径，UI 只把它当「已保存到此位置」的展示串（PRD 九.4）。
  /// 用户取消返回 null；设备无任何 DocumentsProvider 时插件抛
  /// `PlatformException(activity_not_found)`，交由上层错误卡片兜底。
  Future<ExportResult?> _saveWithSystemDialog({
    required String suggestedName,
    required Uint8List bytes,
    required List<String>? mimeTypes,
  }) async {
    final path = await FlutterFileDialog.saveFile(
      params: SaveFileDialogParams(
        data: bytes,
        fileName: suggestedName,
        mimeTypesFilter: mimeTypes,
      ),
    );
    if (path == null) return null;
    return ExportResult(savedPath: path);
  }
}
