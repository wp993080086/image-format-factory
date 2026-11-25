import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/router.dart';
import '../../core/di/providers.dart';
import '../../core/error/app_error.dart';
import '../../core/image/image_format.dart';
import '../../core/platform/capabilities.dart';
import '../../services/file/import_service.dart';
import '../editor/editor_controller.dart';
import '../editor/editor_state.dart';

/// 首页：图片导入入口 + MVP 功能入口。
///
/// 四个入口对应三个页面：裁剪、尺寸与比例、导出。格式转换与图片压缩是同一个
/// 导出面板（参数同屏、一次编码，PRD 四章首 / 五.6），仅入口文案不同。
///
/// 导入能力（读取文件头、像素预检、Isolate 解码生成预览图）统一由
/// [editorControllerProvider] 承担，功能页与首页共用同一份状态。
class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage> {
  /// 拖拽悬停中：盖一层提示遮罩（仅 Windows 启用，见七.1）。
  bool _dragging = false;

  /// 拖拽落地：单文件直接导入，多文件只取第一个并提示（PRD 六.5）。
  Future<void> _handleDrop(DropDoneDetails detail) async {
    if (_dragging) setState(() => _dragging = false);
    final files = detail.files;
    if (files.isEmpty) return;

    final messenger = ScaffoldMessenger.of(context);
    if (files.length > 1) {
      messenger.showSnackBar(
        const SnackBar(content: Text('当前版本一次只处理一张图片，已取第一张')),
      );
    }

    final file = files.first;
    try {
      final result = await ref
          .read(importServiceProvider)
          .readFileAt(file.path, name: file.name);
      if (result == null) return;
      // 非图片直接提示，不进入解码（PRD 六.5：停留在当前页）
      if (result.format == null) {
        messenger.showSnackBar(const SnackBar(content: Text('不支持的文件类型')));
        return;
      }
      await ref.read(editorControllerProvider.notifier).loadImport(result);
    } catch (_) {
      messenger.showSnackBar(const SnackBar(content: Text('无法读取该文件')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final caps = ref.watch(capabilitiesProvider);
    final state = ref.watch(editorControllerProvider);

    final content = Scaffold(
      appBar: AppBar(
        title: const Text('图片格式工厂'),
        actions: [
          IconButton(
            tooltip: '关于',
            onPressed: () => context.push(AppRoutes.about),
            icon: const Icon(Icons.info_outline),
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _ImportCard(
                caps: caps,
                state: state,
                onImport: () =>
                    ref.read(editorControllerProvider.notifier).pickAndLoad(),
              ),
              const SizedBox(height: 16),
              // v0.5 / M3：统一批量入口。新旧流程并存，旧单图入口保留为别名。
              Card(
                color: Theme.of(context).colorScheme.primaryContainer,
                child: ListTile(
                  leading: const Icon(Icons.auto_awesome_mosaic_outlined),
                  title: const Text('批量处理（新）'),
                  subtitle: const Text('多图一次配置：格式/调色/水印/标注，可导出动图'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => context.push(AppRoutes.pipeline),
                ),
              ),
              const SizedBox(height: 16),
              Text('功能', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              // 已成功导入且不在「中」态即可进入功能页（含导出完成后的 done 态，
              // 否则用户从导出页返回后入口会全部置灰、无路可走）。
              _FeatureGrid(enabled: state.imported != null && !state.busy),
            ],
          ),
        ),
      ),
    );

    // 拖拽只在支持的端挂载，避免其它端无谓地初始化平台通道
    if (!caps.dragDropImport) return content;
    return DropTarget(
      onDragEntered: (_) => setState(() => _dragging = true),
      onDragExited: (_) => setState(() => _dragging = false),
      onDragDone: _handleDrop,
      child: Stack(
        children: [
          content,
          if (_dragging) const Positioned.fill(child: _DropOverlay()),
        ],
      ),
    );
  }
}

/// 拖拽悬停遮罩。
class _DropOverlay extends StatelessWidget {
  const _DropOverlay();

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: ColoredBox(
        color: const Color(0x99000000),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.file_download_outlined,
                size: 48,
                color: Colors.white,
              ),
              const SizedBox(height: 12),
              Text(
                '松开以导入图片',
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(color: Colors.white),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ImportCard extends StatelessWidget {
  const _ImportCard({
    required this.caps,
    required this.state,
    required this.onImport,
  });

  final PlatformCapabilities caps;
  final EditorState state;
  final VoidCallback onImport;

  @override
  Widget build(BuildContext context) {
    final hints = <String>[
      if (caps.dragDropImport) '支持拖拽导入',
      if (caps.pasteImport) '支持粘贴导入',
    ];
    final imported = state.imported;
    final decoded = state.decoded;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '导入图片',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      if (hints.isNotEmpty)
                        Text(
                          hints.join(' · '),
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                    ],
                  ),
                ),
                FilledButton.icon(
                  onPressed: state.busy ? null : onImport,
                  icon: const Icon(Icons.file_open),
                  label: const Text('选择文件'),
                ),
              ],
            ),
            if (state.busy) ...[
              const Divider(height: 24),
              const LinearProgressIndicator(),
              const SizedBox(height: 8),
              Text(state.phase.label),
            ],
            if (state.failure != null) ...[
              const Divider(height: 24),
              _ImportFailure(failure: state.failure!, onRetry: onImport),
            ],
            if (imported != null && decoded != null) ...[
              const Divider(height: 24),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.image_outlined),
                title: Text(imported.fileName),
                subtitle: Text(
                  '${imported.format?.displayName ?? '未知格式'} · ${imported.sizeDisplay}'
                  ' · ${decoded.sourceSize.width}×${decoded.sourceSize.height}'
                  '${imported.isAnimated ? ' · 动图' : ''}'
                  '${imported.format?.supportsAlpha == true ? ' · 含透明通道' : ''}',
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 导入失败提示：错误码 + 文案 + 出口按钮（PRD 九.4）。
class _ImportFailure extends StatelessWidget {
  const _ImportFailure({required this.failure, required this.onRetry});

  final AppFailure failure;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.error_outline, color: scheme.error),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${failure.code.code} ${failure.message}',
                style: TextStyle(color: scheme.error),
              ),
              const SizedBox(height: 8),
              OutlinedButton(onPressed: onRetry, child: const Text('重新选择')),
            ],
          ),
        ),
      ],
    );
  }
}

class _FeatureGrid extends StatelessWidget {
  const _FeatureGrid({required this.enabled});

  /// 未导入图片时功能入口置灰（PRD 九.5：可编辑态才允许进入功能页）。
  final bool enabled;

  static const _items = <_FeatureItem>[
    _FeatureItem(Icons.crop, '裁剪', AppRoutes.crop),
    _FeatureItem(Icons.photo_size_select_large, '尺寸与比例', AppRoutes.resize),
    _FeatureItem(Icons.swap_horiz, '格式转换', AppRoutes.exportPanel),
    _FeatureItem(Icons.compress, '图片压缩', AppRoutes.exportPanel),
    _FeatureItem(Icons.draw, '标注与打码', AppRoutes.annotate),
  ];

  @override
  Widget build(BuildContext context) {
    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 8,
      crossAxisSpacing: 8,
      childAspectRatio: 2.6,
      children: [
        for (final item in _items)
          _FeatureCard(
            icon: item.icon,
            title: item.title,
            enabled: enabled,
            onTap: () => context.push(item.route),
          ),
      ],
    );
  }
}

class _FeatureItem {
  const _FeatureItem(this.icon, this.title, this.route);

  final IconData icon;
  final String title;
  final String route;
}

class _FeatureCard extends StatelessWidget {
  const _FeatureCard({
    required this.icon,
    required this.title,
    required this.enabled,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = enabled
        ? Theme.of(context).colorScheme.primary
        : Theme.of(context).disabledColor;
    return Card(
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(12),
        child: Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: color),
              const SizedBox(width: 12),
              Flexible(
                child: Text(
                  title,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(
                    context,
                  ).textTheme.titleMedium?.copyWith(color: color),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
