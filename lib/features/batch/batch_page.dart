import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/batch/batch_models.dart';
import '../../core/image/image_format.dart';
import '../../core/image/watermark.dart';
import 'batch_controller.dart';

const _positionLabels = <WatermarkPosition, String>{
  WatermarkPosition.topLeft: '左上',
  WatermarkPosition.topRight: '右上',
  WatermarkPosition.bottomLeft: '左下',
  WatermarkPosition.bottomRight: '右下',
  WatermarkPosition.center: '居中',
};

const _watermarkColors = <String, int>{
  '白': 0xFFFFFFFF,
  '黑': 0xFF000000,
  '红': 0xFFFF0000,
  '蓝': 0xFF2196F3,
};

/// 批量任务页（v0.5 / M3）：选多图 → 一次配置 → 批量出图，单图 = N=1。
class BatchPage extends ConsumerWidget {
  const BatchPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(batchControllerProvider);
    final notifier = ref.read(batchControllerProvider.notifier);

    return Scaffold(
      appBar: AppBar(
        title: const Text('批量处理'),
        actions: [
          if (state.stage == BatchStage.running)
            IconButton(
              tooltip: '取消',
              icon: const Icon(Icons.cancel_outlined),
              onPressed: notifier.cancel,
            ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _PickerCard(state: state, notifier: notifier),
              const SizedBox(height: 16),
              if (state.stage == BatchStage.configuring) ...[
                _ConfigCard(config: state.config, notifier: notifier),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: notifier.run,
                  icon: const Icon(Icons.play_arrow),
                  label: Text('开始批量导出（${state.items.length} 张）'),
                ),
              ],
              if (state.stage == BatchStage.running) ...[
                _ProgressCard(state: state),
              ],
              if (state.stage == BatchStage.done) ...[
                _ResultCard(state: state, notifier: notifier),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _PickerCard extends StatelessWidget {
  const _PickerCard({required this.state, required this.notifier});

  final BatchState state;
  final BatchController notifier;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '选择图片',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                FilledButton.icon(
                  onPressed: state.busy ? null : notifier.pickImages,
                  icon: const Icon(Icons.photo_library_outlined),
                  label: Text(state.items.isEmpty ? '选择图片' : '继续添加'),
                ),
              ],
            ),
            if (state.skippedDuplicates > 0)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '已跳过 ${state.skippedDuplicates} 张重复图片',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
              ),
            if (state.items.isNotEmpty) ...[
              const Divider(height: 24),
              Text('已选 ${state.items.length} 张：'),
              const SizedBox(height: 8),
              ...state.items.map(
                (i) => ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.image_outlined),
                  title: Text(i.fileName),
                  trailing: state.busy
                      ? null
                      : IconButton(
                          tooltip: '移除 ${i.fileName}',
                          icon: const Icon(Icons.close_outlined),
                          onPressed: () => notifier.removeItem(i.id),
                        ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ConfigCard extends StatelessWidget {
  const _ConfigCard({required this.config, required this.notifier});

  final BatchConfig config;
  final BatchController notifier;

  @override
  Widget build(BuildContext context) {
    final exportable = <ImageFormat>[
      ImageFormat.png,
      ImageFormat.jpeg,
      ImageFormat.bmp,
      ImageFormat.webp,
      ImageFormat.tiff,
      ImageFormat.gif,
    ].where(notifier.canExport).toList();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('统一配置', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            DropdownButtonFormField<ImageFormat>(
              initialValue: exportable.contains(config.targetFormat)
                  ? config.targetFormat
                  : exportable.first,
              decoration: const InputDecoration(labelText: '目标格式'),
              items: [
                for (final f in exportable)
                  DropdownMenuItem(value: f, child: Text(f.displayName)),
              ],
              onChanged: (v) {
                if (v != null) {
                  notifier.updateConfig(config.copyWithTargetFormat(v));
                }
              },
            ),
            if (config.targetFormat == ImageFormat.gif &&
                notifier.hasAnimatedItem &&
                notifier.canExportAnimation)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('导出为动图'),
                subtitle: const Text('保留源 GIF 的帧序与延时；关闭则只导出首帧'),
                value: config.exportAnimation,
                onChanged: (on) =>
                    notifier.updateConfig(config.copyWith(exportAnimation: on)),
              ),
            const SizedBox(height: 12),
            Text('JPEG/WebP 质量：${config.quality}'),
            Slider(
              value: config.quality.toDouble(),
              min: 1,
              max: 100,
              divisions: 99,
              onChanged: (v) =>
                  notifier.updateConfig(config.copyWith(quality: v.round())),
            ),
            const SizedBox(height: 12),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('按目标体积压缩'),
              subtitle: Text(
                config.targetKb == null
                    ? '关闭：按上方质量导出'
                    : '目标 ≤ ${config.targetKb} KB（有损格式）',
              ),
              value: config.targetKb != null,
              onChanged: (on) => notifier.updateConfig(
                on
                    ? config.copyWith(targetKb: 100)
                    : config.copyWith(clearTargetKb: true),
              ),
            ),
            if (config.targetKb != null)
              TextFormField(
                initialValue: '${config.targetKb}',
                decoration: const InputDecoration(labelText: '目标大小（KB）'),
                keyboardType: TextInputType.number,
                onChanged: (v) {
                  final kb = int.tryParse(v);
                  if (kb != null && kb > 0) {
                    notifier.updateConfig(config.copyWith(targetKb: kb));
                  }
                },
              ),
            const SizedBox(height: 12),
            Text('基础调色', style: Theme.of(context).textTheme.bodyLarge),
            _ColorSlider(
              label: '亮度',
              value: config.colorAdjust.brightness,
              onChanged: (v) => notifier.updateConfig(
                config.copyWith(
                  colorAdjust: config.colorAdjust.copyWith(brightness: v),
                ),
              ),
            ),
            _ColorSlider(
              label: '对比度',
              value: config.colorAdjust.contrast,
              onChanged: (v) => notifier.updateConfig(
                config.copyWith(
                  colorAdjust: config.colorAdjust.copyWith(contrast: v),
                ),
              ),
            ),
            _ColorSlider(
              label: '饱和度',
              value: config.colorAdjust.saturation,
              onChanged: (v) => notifier.updateConfig(
                config.copyWith(
                  colorAdjust: config.colorAdjust.copyWith(saturation: v),
                ),
              ),
            ),
            const SizedBox(height: 12),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('文字水印'),
              value: config.watermark != null,
              onChanged: (on) => notifier.updateConfig(
                config.copyWith(
                  watermark: on
                      ? const TextWatermark(text: 'PIXEL FORGE')
                      : null,
                ),
              ),
            ),
            if (config.watermark != null) ...[
              TextFormField(
                initialValue: config.watermark!.text,
                decoration: const InputDecoration(labelText: '水印文字'),
                onChanged: (v) => notifier.updateConfig(
                  config.copyWith(watermark: config.watermark!.copyWithText(v)),
                ),
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('全屏重复（平铺）'),
                subtitle: const Text('开启后忽略下方位置'),
                value: config.watermark!.repeat,
                onChanged: (on) => notifier.updateConfig(
                  config.copyWith(
                    watermark: config.watermark!.copyWith(repeat: on),
                  ),
                ),
              ),
              if (!config.watermark!.repeat)
                DropdownButtonFormField<WatermarkPosition>(
                  initialValue: config.watermark!.position,
                  decoration: const InputDecoration(labelText: '位置'),
                  items: [
                    for (final p in WatermarkPosition.values)
                      DropdownMenuItem(
                        value: p,
                        child: Text(_positionLabels[p]!),
                      ),
                  ],
                  onChanged: (v) {
                    if (v != null) {
                      notifier.updateConfig(
                        config.copyWith(
                          watermark: config.watermark!.copyWith(position: v),
                        ),
                      );
                    }
                  },
                ),
              Text('字号：${config.watermark!.fontSize}'),
              Slider(
                value: config.watermark!.fontSize.toDouble(),
                min: 12,
                max: 96,
                divisions: 84,
                onChanged: (v) => notifier.updateConfig(
                  config.copyWith(
                    watermark: config.watermark!.copyWith(fontSize: v.round()),
                  ),
                ),
              ),
              Text('透明度：${config.watermark!.opacity}%'),
              Slider(
                value: config.watermark!.opacity.toDouble(),
                min: 10,
                max: 100,
                divisions: 90,
                onChanged: (v) => notifier.updateConfig(
                  config.copyWith(
                    watermark: config.watermark!.copyWith(opacity: v.round()),
                  ),
                ),
              ),
              Text('颜色', style: Theme.of(context).textTheme.bodySmall),
              Wrap(
                spacing: 8,
                children: [
                  for (final entry in _watermarkColors.entries)
                    ChoiceChip(
                      label: Text(entry.key),
                      selected: config.watermark!.colorArgb == entry.value,
                      onSelected: (_) => notifier.updateConfig(
                        config.copyWith(
                          watermark: config.watermark!.copyWith(
                            colorArgb: entry.value,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ],
            const SizedBox(height: 8),
            Text(
              '调色/水印/标注的核心算法已就绪，批量统一套用。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _ColorSlider extends StatelessWidget {
  const _ColorSlider({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final int value;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(width: 64, child: Text(label)),
        Expanded(
          child: Slider(
            value: value.toDouble(),
            min: -100,
            max: 100,
            divisions: 200,
            onChanged: (v) => onChanged(v.round()),
          ),
        ),
        SizedBox(width: 40, child: Text('$value', textAlign: TextAlign.end)),
      ],
    );
  }
}

class _ProgressCard extends StatelessWidget {
  const _ProgressCard({required this.state});

  final BatchState state;

  @override
  Widget build(BuildContext context) {
    final p = state.progress;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('正在处理 ${p?.done ?? 0}/${p?.total ?? state.items.length}'),
            const SizedBox(height: 8),
            LinearProgressIndicator(value: p?.fraction ?? 0),
            if (p?.currentName != null) ...[
              const SizedBox(height: 8),
              Text(
                '当前：${p!.currentName}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ResultCard extends StatelessWidget {
  const _ResultCard({required this.state, required this.notifier});

  final BatchState state;
  final BatchController notifier;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '完成：成功 ${state.successCount}，失败 ${state.failCount}',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            ...state.results.map(
              (r) => ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  r.isSuccess ? Icons.check_circle : Icons.error_outline,
                  color: r.isSuccess ? Colors.green : Colors.red,
                ),
                title: Text(r.item.fileName),
                subtitle: Text(
                  r.isSuccess ? (r.savedPath ?? '已保存') : '${r.error}',
                ),
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: notifier.reset,
              icon: const Icon(Icons.add),
              label: const Text('处理下一批'),
            ),
          ],
        ),
      ),
    );
  }
}
