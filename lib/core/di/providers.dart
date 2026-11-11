import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../image/decode_service.dart';
import '../image/encode_service.dart';
import '../log/app_logger.dart';
import '../platform/app_platform.dart';
import '../platform/capabilities.dart';
import '../../services/file/export_service.dart';

/// 诊断日志聚合函数的签名（PRD 十六.2）。
typedef DiagnosticsCollector = Future<String> Function({String header});

/// 诊断日志聚合器。
///
/// 单独抽成 provider 而不是让「关于」页直接调 [AppLogger]：聚合过程要读磁盘，
/// 组件测试里没有 path_provider 通道，直接调用会永久挂起。
final diagnosticsProvider = Provider<DiagnosticsCollector>(
  (ref) => AppLogger.collectDiagnostics,
);

/// 当前端能力矩阵（全局只读）。
final capabilitiesProvider = Provider<PlatformCapabilities>(
  (ref) => PlatformCapabilities.of(AppPlatform.current),
);

final exportServiceProvider = Provider<ExportService>(
  (ref) => const ExportService(),
);

/// 图片解码服务（Isolate 内解码 + 生成预览图）。
final decodeServiceProvider = Provider<DecodeService>(
  (ref) => const DecodeService(),
);

/// 图片编码服务（Isolate 内二次解码全图 + 编码），供导出使用。
final encodeServiceProvider = Provider<EncodeService>(
  (ref) => const EncodeService(),
);

// 说明：importServiceProvider 定义在 `services/file/import_service.dart`，
// editorControllerProvider 定义在 `features/editor/editor_controller.dart`，
// 以避免 providers.dart ↔ controller 的循环依赖。
