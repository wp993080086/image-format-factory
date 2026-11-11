/// 诊断日志的落盘命名与保留策略（PRD 十六.2）。
///
/// 策略本身是纯函数，便于单测；真正的文件读写隔离在 `log_file.dart`。
library;

/// 日志文件名前缀 / 后缀。
const String logFilePrefix = 'pf-';
const String logFileExtension = '.log';

/// 保留最近 3 次会话（PRD 十六.2）。
const int logSessionsKept = 3;

/// 生成会话日志文件名：`pf-20261111-101500.log`。
///
/// 采用「零填充 + 固定宽度」的时间格式，字典序即时间序，
/// 因此保序/淘汰不需要解析日期。
String buildLogFileName(DateTime time) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '$logFilePrefix${time.year}${two(time.month)}${two(time.day)}'
      '-${two(time.hour)}${two(time.minute)}${two(time.second)}'
      '$logFileExtension';
}

/// 是否是本应用产生的日志文件。
bool isLogFileName(String name) =>
    name.startsWith(logFilePrefix) && name.endsWith(logFileExtension);

/// 计算超出保留份数、应当删除的文件名（最旧的在前）。
///
/// 只统计符合命名规则的文件，避免误删同目录下的其它内容。
List<String> logsToPrune(List<String> fileNames, {int keep = logSessionsKept}) {
  final logs = fileNames.where(isLogFileName).toList()..sort();
  if (logs.length <= keep) return const <String>[];
  return logs.sublist(0, logs.length - keep);
}

/// 选出最近 [sessions] 个会话的日志文件名（最新的在前）。
List<String> recentLogFiles(
  List<String> fileNames, {
  int sessions = logSessionsKept,
}) {
  final logs = fileNames.where(isLogFileName).toList()..sort();
  if (logs.length <= sessions) return logs.reversed.toList();
  return logs.sublist(logs.length - sessions).reversed.toList();
}
