import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/app_info.dart';
import '../../app/native_licenses.dart';
import '../../core/di/providers.dart';
import '../../core/log/app_logger.dart';
import '../../core/platform/app_platform.dart';
import '../../services/file/export_service.dart';

/// 关于页（PRD 十三、十六章）：版本、隐私说明、开源许可、诊断日志导出。
///
/// 隐私说明与许可声明是 Windows Store / 各 Android 应用市场的上架硬要求，
/// 即使应用完全离线也必须提供，因此放在显眼位置而不是折叠起来。
class AboutPage extends ConsumerStatefulWidget {
  const AboutPage({super.key});

  @override
  ConsumerState<AboutPage> createState() => _AboutPageState();
}

class _AboutPageState extends ConsumerState<AboutPage> {
  bool _exporting = false;

  /// 诊断日志头部：排障时最需要的前置信息。
  String get _diagnosticHeader =>
      '$appName $appVersionLabel\n'
      '运行平台：${AppPlatform.current.displayName}';

  /// `imageformatfactory-log-20261111-101500.txt`
  String get _diagnosticFileName {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final stamp =
        '${now.year}${two(now.month)}${two(now.day)}'
        '-${two(now.hour)}${two(now.minute)}${two(now.second)}';
    return 'imageformatfactory-log-$stamp.txt';
  }

  Future<void> _exportDiagnostics() async {
    if (_exporting) return;
    setState(() => _exporting = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final text = await ref.read(diagnosticsProvider)(
        header: _diagnosticHeader,
      );
      final result = await ref
          .read(exportServiceProvider)
          .saveAs(
            suggestedName: _diagnosticFileName,
            bytes: Uint8List.fromList(utf8.encode(text)),
            extensions: const ['txt'],
            label: '文本文件',
            mimeTypes: const ['text/plain'],
          );
      // 用户取消保存面板：什么都不做，不算失败
      if (result == null) return;
      messenger.showSnackBar(
        SnackBar(content: Text('诊断日志已保存：${displaySavedPath(result.savedPath)}')),
      );
    } catch (e, st) {
      AppLogger.error('导出诊断日志失败', name: 'about', error: e, stackTrace: st);
      messenger.showSnackBar(const SnackBar(content: Text('导出失败，请重试')));
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  /// 展示原生库的许可全文（LGPL-3.0 要求分发时附许可文本）。
  Future<void> _showNativeLicense(NativeLibraryLicense lib) async {
    final messenger = ScaffoldMessenger.of(context);
    String text;
    try {
      text = await rootBundle.loadString(lib.assetPath);
    } catch (e, st) {
      AppLogger.error(
        '读取许可全文失败',
        name: 'about',
        error: e,
        stackTrace: st,
      );
      messenger.showSnackBar(const SnackBar(content: Text('许可文本读取失败')));
      return;
    }
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('${lib.name} ${lib.version}'),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: SelectableText(
              text,
              style: const TextStyle(fontSize: 11, height: 1.4),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('关于')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              const Card(
                child: ListTile(
                  leading: Icon(Icons.photo_size_select_large),
                  title: Text(appName),
                  subtitle: Text('版本 $appVersionLabel'),
                ),
              ),
              const SizedBox(height: 16),
              Text('隐私说明', style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final point in privacyPoints)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Icon(
                                Icons.check,
                                size: 16,
                                color: theme.colorScheme.primary,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  point,
                                  style: theme.textTheme.bodyMedium,
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text('开源许可', style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              Card(
                child: ListTile(
                  leading: const Icon(Icons.description_outlined),
                  title: const Text('第三方组件许可'),
                  subtitle: const Text('Flutter、image、file_selector 等'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => showLicensePage(
                    context: context,
                    applicationName: appName,
                    applicationVersion: appVersionLabel,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Card(
                child: ExpansionTile(
                  leading: const Icon(Icons.extension_outlined),
                  title: const Text('原生库许可'),
                  subtitle: const Text('Windows 端随包分发的编解码库'),
                  childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  children: [
                    for (final lib in nativeLibraryLicenses)
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text('${lib.name} ${lib.version}'),
                        subtitle: Text('${lib.license} · ${lib.purpose}'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => _showNativeLicense(lib),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Text('诊断日志', style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '日志只保存在本机应用目录，最多保留最近 3 次会话、'
                        '单个会话上限 2MB。遇到问题时可导出发给开发者，'
                        '导出前请自行确认其中不含敏感路径。',
                        style: theme.textTheme.bodySmall,
                      ),
                      const SizedBox(height: 12),
                      OutlinedButton.icon(
                        onPressed: _exporting ? null : _exportDiagnostics,
                        icon: const Icon(Icons.download_outlined),
                        label: Text(_exporting ? '正在导出…' : '导出诊断日志'),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
