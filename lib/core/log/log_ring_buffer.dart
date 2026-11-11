import 'dart:convert';

/// 内存环形日志缓冲：按**字节**上限淘汰最旧的行（PRD 十六.2：单文件上限 2MB）。
///
/// 按字节而非行数计容量，因为日志里混有文件路径、错误栈等长文本，
/// 行数相同的两个会话体积可能差一个数量级。
///
/// 单行本身超过上限时会被立即丢弃（连同之前的所有行），保证内存不被
/// 一条异常巨大的错误栈撑爆。
class LogRingBuffer {
  LogRingBuffer({this.maxBytes = defaultMaxBytes});

  /// 单会话日志上限 2MB（PRD 十六.2）。
  static const int defaultMaxBytes = 2 * 1024 * 1024;

  final int maxBytes;

  final List<String> _lines = <String>[];
  int _bytes = 0;

  /// 当前保有的日志行（只读视图，按写入顺序）。
  List<String> get lines => List.unmodifiable(_lines);

  /// 当前占用字节数（UTF-8 编码后的实际体积）。
  int get byteCount => _bytes;

  int get length => _lines.length;

  bool get isEmpty => _lines.isEmpty;

  /// 全部日志拼成文本，供落盘与导出。
  String get text => _lines.join('\n');

  /// 追加一行；超出上限时从头淘汰，直到装得下。
  void add(String line) {
    final size = utf8.encode(line).length;
    _lines.add(line);
    _bytes += size;
    while (_bytes > maxBytes && _lines.isNotEmpty) {
      _bytes -= utf8.encode(_lines.removeAt(0)).length;
    }
  }

  void addAll(Iterable<String> lines) {
    for (final line in lines) {
      add(line);
    }
  }

  void clear() {
    _lines.clear();
    _bytes = 0;
  }
}
