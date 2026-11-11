import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';

import '../../core/image/image_format.dart';
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

/// 图片导出服务：封装各端保存差异（PRD 六.2）。
class ExportService {
  const ExportService();

  /// 唤起系统保存面板并写入文件；用户取消时返回 null。
  Future<ExportResult?> save(ExportRequest request) async {
    final group = XTypeGroup(
      label: request.format.displayName,
      extensions: request.format.extensions,
    );
    final location = await getSaveLocation(
      suggestedName: request.suggestedName,
      acceptedTypeGroups: [group],
    );
    if (location == null) return null;

    await writeBytesToFile(location.path, request.bytes);
    return ExportResult(savedPath: location.path);
  }
}
