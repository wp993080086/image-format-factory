/// 诊断日志落盘的平台隔离层。
///
/// 直接导出 native 实现（Windows / Android / 鸿蒙均有文件系统）。
library;

export 'log_file_native.dart';
