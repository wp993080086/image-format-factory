import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';

import 'log_file.dart';
import 'log_retention.dart';
import 'log_ring_buffer.dart';

/// 日志级别（对应 AGENTS.md 编码规范）。
enum LogLevel {
  debug,
  info,
  warn,
  error;

  /// 是否达到输出阈值：[kDebugMode] 下全量输出，release 仅 warn/error。
  bool get enabled => kDebugMode || index >= LogLevel.warn.index;
}

/// 应用日志薄封装。
///
/// 设计约束（PRD 铁律：纯本地离线）：
/// - 零第三方依赖，底层用 [developer.log]，可在 DevTools / IDE 控制台查看；
/// - **不做任何远程上报**，禁止接入 Sentry / Firebase 等联网日志；
/// - release 下仅保留 [LogLevel.warn] 及以上，避免生产噪音。
///
/// 落盘能力（PRD 十六.2）：所有日志同时进内存环形缓冲，按 2MB 上限淘汰最旧
/// 的行；写入后 2 秒防抖落盘到 `<应用支持目录>/logs/pf-*.log`，只保留最近
/// 3 次会话。**落盘失败绝不影响主流程**——日志是旁路，不是依赖。
///
/// 用法：
/// ```dart
/// AppLogger.info('导入完成', name: 'import', data: {'format': 'png'});
/// AppLogger.error('解码失败', error: e, stackTrace: st, name: 'decode');
/// ```
class AppLogger {
  AppLogger._();

  /// 统一日志名（DevTools 里按此过滤）。
  static const String _defaultName = 'image_format_factory';

  /// 会话缓冲：即使未落盘也要留存，供「导出诊断日志」使用。
  static final LogRingBuffer _buffer = LogRingBuffer();

  static String? _sessionFile;
  static Timer? _flushTimer;
  static bool _persist = false;

  /// 当前会话的内存缓冲（调试与导出诊断日志用）。
  static LogRingBuffer get buffer => _buffer;

  /// 当前会话的日志文件名；未开始会话时为 null。
  static String? get sessionFile => _sessionFile;

  /// 开始一次会话：生成日志文件名，并清掉超出保留份数的旧日志。
  ///
  /// [persist] 为 false 时只留内存缓冲（测试环境与 Web 端）。
  /// 同步部分（文件名、持久化开关）在首个 await 之前完成，
  /// 因此调用方可以直接 `unawaited(AppLogger.startSession())`。
  static Future<void> startSession({
    DateTime? now,
    bool persist = true,
  }) async {
    _sessionFile = buildLogFileName(now ?? DateTime.now());
    _persist = persist;
    _buffer.clear();
    if (!persist) return;
    try {
      final pruned = logsToPrune(await listLogFiles());
      if (pruned.isNotEmpty) await deleteLogFiles(pruned);
    } catch (_) {
      // 清理失败不影响本次运行
    }
  }

  /// 立即把当前会话缓冲写盘。
  ///
  /// 除退出前的兜底外，「关于」页导出日志前也会调一次，
  /// 保证导出的内容与磁盘上看到的一致。
  static Future<void> flush() async {
    _flushTimer?.cancel();
    _flushTimer = null;
    final file = _sessionFile;
    if (!_persist || file == null) return;
    final text = _buffer.text;
    if (text.isEmpty) return;
    try {
      await writeLogFile(file, text);
    } catch (_) {
      // 磁盘不可写不能反过来影响主流程
    }
  }

  /// 汇总诊断日志：可选头部 + 当前会话 + 最近的历史会话。
  ///
  /// 历史会话读盘失败时只返回当前会话，不抛异常——用户点「导出诊断日志」
  /// 的诉求是「拿到能看的东西」，而不是拿到一个错误弹窗。
  static Future<String> collectDiagnostics({String header = ''}) async {
    await flush();
    final sb = StringBuffer();
    if (header.isNotEmpty) {
      sb
        ..writeln(header)
        ..writeln();
    }
    sb.writeln('会话文件：${_sessionFile ?? '（未开始）'}');
    sb.writeln('生成时间：${DateTime.now().toIso8601String()}');
    sb.writeln();
    sb.writeln('===== 当前会话 =====');
    sb.writeln(_buffer.isEmpty ? '（本次会话无日志）' : _buffer.text);

    try {
      final names = recentLogFiles(
        await listLogFiles(),
        sessions: logSessionsKept,
      );
      for (final name in names) {
        if (name == _sessionFile) continue;
        final content = await readLogFile(name);
        if (content == null) continue;
        sb
          ..writeln()
          ..writeln('===== 历史会话 $name =====')
          ..writeln(content);
      }
    } catch (_) {
      sb
        ..writeln()
        ..writeln('（历史会话读取失败）');
    }
    return sb.toString();
  }

  static void debug(String message, {String? name, Object? data}) {
    _log(LogLevel.debug, message, name: name, data: data);
  }

  static void info(String message, {String? name, Object? data}) {
    _log(LogLevel.info, message, name: name, data: data);
  }

  static void warn(
    String message, {
    String? name,
    Object? error,
    StackTrace? stackTrace,
    Object? data,
  }) {
    _log(
      LogLevel.warn,
      message,
      name: name,
      error: error,
      stackTrace: stackTrace,
      data: data,
    );
  }

  static void error(
    String message, {
    String? name,
    Object? error,
    StackTrace? stackTrace,
    Object? data,
  }) {
    _log(
      LogLevel.error,
      message,
      name: name,
      error: error,
      stackTrace: stackTrace,
      data: data,
    );
  }

  static void _log(
    LogLevel level,
    String message, {
    String? name,
    Object? error,
    StackTrace? stackTrace,
    Object? data,
  }) {
    final line = _format(level, message, name: name, data: data);
    // 缓冲不按级别过滤：诊断日志要看的是完整上下文，
    // 控制台输出才受 release 阈值约束
    _buffer.add(line);
    _scheduleFlush();
    if (!level.enabled) return;
    developer.log(
      line,
      name: name ?? _defaultName,
      error: error,
      stackTrace: stackTrace,
      level: _developerLevel(level),
    );
  }

  static String _format(
    LogLevel level,
    String message, {
    String? name,
    Object? data,
  }) {
    final time = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final stamp =
        '${two(time.hour)}:${two(time.minute)}:${two(time.second)}.'
        '${time.millisecond.toString().padLeft(3, '0')}';
    final buffer = StringBuffer('$stamp [${level.name.toUpperCase()}] $message');
    if (name != null) buffer.write(' ($name)');
    if (data != null) buffer.write(' | $data');
    return buffer.toString();
  }

  /// 写入后 2 秒防抖落盘：导出大图时会连续打多条日志，
  /// 逐条写盘会让磁盘 IO 干扰编码耗时。
  static void _scheduleFlush() {
    if (!_persist) return;
    _flushTimer?.cancel();
    _flushTimer = Timer(const Duration(seconds: 2), () => unawaited(flush()));
  }

  /// 映射到 `dart:developer` 的 level 数值（便于 DevTools 按级别过滤）。
  static int _developerLevel(LogLevel level) => switch (level) {
    LogLevel.debug => 500,
    LogLevel.info => 800,
    LogLevel.warn => 900,
    LogLevel.error => 1000,
  };
}
