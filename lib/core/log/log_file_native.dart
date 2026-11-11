import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 日志目录：`<应用支持目录>/logs`。
///
/// 用「应用支持目录」而非「文档目录」：日志属于应用内部数据，
/// 不需要出现在用户的文档目录里，也不应随用户清除文档而丢失。
Future<Directory> _logDir() async {
  final base = await getApplicationSupportDirectory();
  final dir = Directory(p.join(base.path, 'logs'));
  if (!dir.existsSync()) {
    await dir.create(recursive: true);
  }
  return dir;
}

/// 覆盖写入一个会话日志文件。
Future<void> writeLogFile(String fileName, String content) async {
  final dir = await _logDir();
  await File(p.join(dir.path, fileName)).writeAsString(content, flush: true);
}

/// 读取单个日志文件；不存在时返回 null。
Future<String?> readLogFile(String fileName) async {
  final dir = await _logDir();
  final file = File(p.join(dir.path, fileName));
  if (!file.existsSync()) return null;
  return file.readAsString();
}

/// 列出日志目录下的文件名（不含子目录）。
Future<List<String>> listLogFiles() async {
  final dir = await _logDir();
  return <String>[
    for (final entity in dir.listSync())
      if (entity is File) p.basename(entity.path),
  ];
}

/// 删除指定日志文件；不存在时静默跳过。
Future<void> deleteLogFiles(Iterable<String> names) async {
  final dir = await _logDir();
  for (final name in names) {
    final file = File(p.join(dir.path, name));
    if (file.existsSync()) await file.delete();
  }
}
