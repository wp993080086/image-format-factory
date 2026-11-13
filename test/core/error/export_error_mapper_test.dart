import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixel_forge/core/error/app_error.dart';
import 'package:pixel_forge/core/error/export_error_mapper.dart';
import 'package:pixel_forge/core/platform/app_platform.dart';

/// 构造一个带 OS 错误码的写盘异常，模拟 `File.writeAsBytes` 的失败。
FileSystemException _fs(int code) =>
    FileSystemException('write failed', r'C:\out\a.png', OSError('', code));

void main() {
  group('Windows 错误码归类', () {
    test('磁盘满（112 / 39）', () {
      for (final code in [112, 39]) {
        expect(
          mapExportError(_fs(code), target: AppTarget.windows),
          AppErrorCode.diskFull,
          reason: 'OS error $code',
        );
      }
    });

    test('文件被占用（32 / 1224）', () {
      for (final code in [32, 1224]) {
        expect(
          mapExportError(_fs(code), target: AppTarget.windows),
          AppErrorCode.fileInUse,
        );
      }
    });

    test('目录不可写 / 不存在', () {
      for (final code in [2, 3, 5, 267]) {
        expect(
          mapExportError(_fs(code), target: AppTarget.windows),
          AppErrorCode.pathNotWritable,
          reason: 'OS error $code',
        );
      }
    });

    test('路径非法或过长（123 / 206）', () {
      for (final code in [123, 206]) {
        expect(
          mapExportError(_fs(code), target: AppTarget.windows),
          AppErrorCode.invalidPath,
        );
      }
    });
  });

  group('POSIX 错误码归类', () {
    test('磁盘满 ENOSPC（28）', () {
      expect(
        mapExportError(_fs(28), target: AppTarget.android),
        AppErrorCode.diskFull,
      );
    });

    test('目录不可写 EACCES（13）——同一个数字在 Windows 是别的含义', () {
      expect(
        mapExportError(_fs(13), target: AppTarget.android),
        AppErrorCode.pathNotWritable,
      );
      // Windows 的 13 是 ERROR_INVALID_DATA，不该被当成权限问题
      expect(
        mapExportError(_fs(13), target: AppTarget.windows),
        AppErrorCode.encodeFailed,
      );
    });

    test('只读文件系统 EROFS（30）', () {
      expect(
        mapExportError(_fs(30), target: AppTarget.harmony),
        AppErrorCode.pathNotWritable,
      );
    });

    test('文件被占用 EBUSY（16）', () {
      expect(
        mapExportError(_fs(16), target: AppTarget.android),
        AppErrorCode.fileInUse,
      );
    });

    test('文件名过长 ENAMETOOLONG（36）', () {
      expect(
        mapExportError(_fs(36), target: AppTarget.android),
        AppErrorCode.invalidPath,
      );
    });
  });

  group('Android SAF 平台异常', () {
    test('URI 授权被回收 → 权限被拒', () {
      expect(
        mapExportError(
          PlatformException(code: 'security_exception'),
          target: AppTarget.android,
        ),
        AppErrorCode.permissionDenied,
      );
    });

    test('没有可用的 DocumentsProvider → 位置不可写', () {
      expect(
        mapExportError(
          PlatformException(code: 'activity_not_found'),
          target: AppTarget.android,
        ),
        AppErrorCode.pathNotWritable,
      );
    });

    test('插件内部失败 → E-EXPORT-006', () {
      for (final code in [
        'save_file_failed',
        'file_copy_failed',
        'internal_error',
      ]) {
        expect(
          mapExportError(
            PlatformException(code: code),
            target: AppTarget.android,
          ),
          AppErrorCode.encodeFailed,
        );
      }
    });
  });

  group('兜底', () {
    test('没有 OS 错误码时按「位置不可写」处理', () {
      expect(
        mapExportError(
          const FileSystemException('denied'),
          target: AppTarget.windows,
        ),
        AppErrorCode.pathNotWritable,
      );
    });

    test('非文件系统异常落到 E-EXPORT-006', () {
      expect(mapExportError(StateError('boom')), AppErrorCode.encodeFailed);
      expect(
        mapExportError(UnsupportedError('鸿蒙通道未接入')),
        AppErrorCode.encodeFailed,
      );
    });
  });
}
