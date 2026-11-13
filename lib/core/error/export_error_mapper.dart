import 'package:flutter/services.dart';

import '../../services/file/file_io.dart';
import '../platform/app_platform.dart';
import 'app_error.dart';

/// 把导出阶段的异常归类到 PRD 九.2 的错误码。
///
/// 之前 `export()` 用一个 catch 兜住所有异常，全部报 `E-EXPORT-006`
/// 「导出失败，请尝试降低尺寸或更换格式」——磁盘满、目录只读、文件被占用
/// 的用户会照着这句话去改尺寸，改完还是失败。错误码表定义了五种细分场景
/// 却一个都没被触发过，所以在这里补上归类。
///
/// [target] 可注入，便于在 Windows 机器上跑 POSIX 分支的用例。
AppErrorCode mapExportError(Object error, {AppTarget? target}) {
  final resolved = target ?? AppPlatform.current;

  // Android SAF 的失败走平台通道，错误码由插件给出
  // （源码见 flutter_file_dialog 的 DocumentSaver / FileDialog）。
  if (error is PlatformException) {
    return switch (error.code) {
      // SecurityException：目标目录的 URI 授权被回收
      'security_exception' => AppErrorCode.permissionDenied,
      // ActivityNotFoundException：设备上没有可用的 DocumentsProvider
      'activity_not_found' => AppErrorCode.pathNotWritable,
      // save_file_failed / file_copy_failed / internal_error
      _ => AppErrorCode.encodeFailed,
    };
  }

  final fromFileSystem = classifyFileSystemError(error, resolved);
  if (fromFileSystem != null) return fromFileSystem;

  // 鸿蒙端通道未接入时抛 UnsupportedError（ADR-007，M3 落地）
  return AppErrorCode.encodeFailed;
}
