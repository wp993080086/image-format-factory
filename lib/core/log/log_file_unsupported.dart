/// Web 端实现：没有本地文件系统，日志只留在内存里。
///
/// 诊断日志导出仍可用——走的是保存面板的下载通道，
/// 不依赖这里的落盘能力。
Future<void> writeLogFile(String fileName, String content) async {}

Future<String?> readLogFile(String fileName) async => null;

Future<List<String>> listLogFiles() async => const <String>[];

Future<void> deleteLogFiles(Iterable<String> names) async {}
