/// 诊断日志落盘的平台隔离层。
///
/// 与 `services/file/file_io.dart` 同样的思路：Web 没有文件系统，
/// 该文件按条件导出，避免 Web 编译时引入 `dart:io`。
library;

export 'log_file_unsupported.dart' if (dart.library.io) 'log_file_native.dart';
