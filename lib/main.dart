import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/app.dart';
import 'core/log/app_logger.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // 开启会话日志：生成会话文件、清理过期日志。
  // 不 await——日志是旁路，绝不能让落盘拖慢首帧。
  unawaited(AppLogger.startSession());
  runApp(const ProviderScope(child: PixelForgeApp()));
}
