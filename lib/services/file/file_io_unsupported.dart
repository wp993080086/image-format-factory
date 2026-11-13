import 'dart:typed_data';

import '../../core/error/app_error.dart';
import '../../core/platform/app_platform.dart';

/// Web 端实现：不支持直接文件写入。
///
/// TODO(Web)：改为触发浏览器下载通道（File System Access API 仅 Chromium 支持，
/// Safari/Firefox 实际为下载行为，见 PRD 附录 #10）。
Future<void> writeBytesToFile(String path, Uint8List bytes) async {
  throw UnsupportedError('Web 端不支持直接文件写入，导出应走下载通道');
}

/// Web 端没有文件系统异常，一律返回 null 交由上层兜底。
AppErrorCode? classifyFileSystemError(Object error, AppTarget target) => null;
