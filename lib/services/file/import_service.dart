import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/image/image_format.dart';
import '../../core/image/format_detector.dart';
import '../../core/platform/app_platform.dart';
import '../../core/platform/capabilities.dart';

/// 导入结果。
class ImportResult {
  const ImportResult({
    required this.fileName,
    required this.bytes,
    required this.format,
    required this.isAnimated,
    required this.extensionMismatch,
  });

  final String fileName;
  final Uint8List bytes;

  /// 格式：优先按文件内容（magic bytes）判定，无法识别时回退扩展名（PRD 一.5）。
  final ImageFormat? format;

  /// 是否为动图（APNG / 动图 WebP / GIF）。
  final bool isAnimated;

  /// 扩展名与内容不一致（内容可识别且与扩展名推断结果不同）。
  final bool extensionMismatch;

  int get sizeInBytes => bytes.length;

  String get sizeDisplay {
    if (sizeInBytes < 1024) return '$sizeInBytes B';
    if (sizeInBytes < 1024 * 1024) {
      return '${(sizeInBytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(sizeInBytes / 1024 / 1024).toStringAsFixed(2)} MB';
  }
}

/// 图片导入服务：封装各端文件选择差异（PRD 六.1）。
class ImportService {
  ImportService(this._capabilities);

  final PlatformCapabilities _capabilities;

  /// 打开系统文件选择器并读取图片字节。
  ///
  /// 用户取消时返回 null。
  /// TODO: Android/鸿蒙走系统文件选择器、Web 增加粘贴导入、
  /// 小程序改相册选择——当前统一走 file_selector。
  Future<ImportResult?> pickImage() async {
    final file = await openFile(acceptedTypeGroups: [importTypeGroup()]);
    if (file == null) return null;

    final bytes = await file.readAsBytes();
    return buildResult(fileName: file.name, bytes: bytes);
  }

  /// 批量选图（v0.5 / M3）：一次选多张，用户取消返回空列表。
  ///
  /// 与 [pickImage] 共用同一套类型过滤与内容探测，单图是 N=1 的特例。
  Future<List<ImportResult>> pickImages() async {
    final files = await openFiles(acceptedTypeGroups: [importTypeGroup()]);
    final result = <ImportResult>[];
    for (final file in files) {
      final bytes = await file.readAsBytes();
      result.add(buildResult(fileName: file.name, bytes: bytes));
    }
    return result;
  }

  /// 文件选择器的类型过滤器。
  ///
  /// 同时给 extensions 与 mimeTypes：桌面端只认 extensions，Android 只认 MIME。
  /// Android 上插件会把 extensions 经 `MimeTypeMap` 转 MIME，转不出来的扩展名
  /// 只打一条 warning 就丢掉——`.ico` 在多数 ROM 上正属于这种，不显式给 MIME
  /// 会让 ICO 文件在选择器里直接不可见。
  XTypeGroup importTypeGroup() => XTypeGroup(
    label: '图片文件',
    extensions: _capabilities.importExtensions,
    mimeTypes: [for (final f in _capabilities.importFormats) f.mimeType],
  );

  /// 从磁盘路径读取（拖拽导入，PRD 六.1）。
  ///
  /// 拖拽与文件选择器共用同一套探测逻辑：扩展名只作回退提示，
  /// 格式最终以内容为准（PRD 一.5）。
  Future<ImportResult?> readFileAt(String path, {String? name}) async {
    final file = XFile(path);
    final bytes = await file.readAsBytes();
    return buildResult(fileName: name ?? file.name, bytes: bytes);
  }

  /// 由文件名字节构造导入结果（文件选择器与拖拽共用）。
  ImportResult buildResult({
    required String fileName,
    required Uint8List bytes,
  }) {
    final dot = fileName.lastIndexOf('.');
    final ext = dot >= 0 ? fileName.substring(dot + 1) : '';
    final byExt = ImageFormat.fromExtension(ext);
    final detected = ImageFormatDetector.detect(bytes);
    // 以内容为准；内容无法识别时回退扩展名（PRD 一.5）。
    final format = detected?.format ?? byExt;
    return ImportResult(
      fileName: fileName,
      bytes: bytes,
      format: format,
      isAnimated: detected?.isAnimated ?? false,
      extensionMismatch: detected != null && byExt != null && byExt != format,
    );
  }
}

/// 导入服务 provider（供状态机控制器读取）。
final importServiceProvider = Provider<ImportService>(
  (ref) => ImportService(PlatformCapabilities.of(AppPlatform.current)),
);
