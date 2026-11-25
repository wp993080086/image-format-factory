import 'dart:io';
import 'dart:typed_data';

import '../../core/error/app_error.dart';
import '../../core/platform/app_platform.dart';

/// 原生端实现：直接写文件系统。
Future<void> writeBytesToFile(String path, Uint8List bytes) async {
  final file = File(path);
  await file.writeAsBytes(bytes, flush: true);
}

/// 把写盘异常归类到 PRD 九.2 的错误码；不是文件系统错误时返回 null。
///
/// 放在这个文件而不是 `core/`：判定要用 `FileSystemException`，需要 `dart:io`。
AppErrorCode? classifyFileSystemError(Object error, AppTarget target) {
  if (error is! FileSystemException) return null;

  final code = error.osError?.errorCode;
  // 没有 OS 错误码（如路径直接构造失败）时，最贴近的语义是「这个位置写不了」。
  if (code == null) return AppErrorCode.pathNotWritable;

  return target == AppTarget.windows ? _classifyWindows(code) : _classifyPosix(code);
}

/// Windows `System Error Codes`。
AppErrorCode _classifyWindows(int code) => switch (code) {
  // ERROR_FILE_NOT_FOUND / ERROR_PATH_NOT_FOUND / ERROR_DIRECTORY
  2 || 3 || 267 => AppErrorCode.pathNotWritable,
  // ERROR_ACCESS_DENIED：只读目录、被 ACL 拒绝
  5 => AppErrorCode.pathNotWritable,
  // ERROR_SHARING_VIOLATION / ERROR_USER_MAPPED_FILE：预览窗格或杀软占着文件
  32 || 1224 => AppErrorCode.fileInUse,
  // ERROR_HANDLE_DISK_FULL / ERROR_DISK_FULL
  39 || 112 => AppErrorCode.diskFull,
  // ERROR_INVALID_NAME / ERROR_FILENAME_EXCED_RANGE
  123 || 206 => AppErrorCode.invalidPath,
  _ => AppErrorCode.encodeFailed,
};

/// POSIX `errno`（Android / 鸿蒙 / Linux / macOS）。
AppErrorCode _classifyPosix(int code) => switch (code) {
  // ENOENT / ENOTDIR / EISDIR / ENOTDIR 的父路径不存在
  2 || 20 || 21 => AppErrorCode.pathNotWritable,
  // EACCES：目录不可写
  13 => AppErrorCode.pathNotWritable,
  // EBUSY
  16 => AppErrorCode.fileInUse,
  // ENOSPC
  28 => AppErrorCode.diskFull,
  // EROFS：只读文件系统
  30 => AppErrorCode.pathNotWritable,
  // ENAMETOOLONG
  36 => AppErrorCode.invalidPath,
  _ => AppErrorCode.encodeFailed,
};
