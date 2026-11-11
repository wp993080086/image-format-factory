import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/router.dart';
import '../../core/di/providers.dart';
import '../../core/error/app_error.dart';
import '../../core/image/crop_selection.dart';
import '../../core/image/encode_service.dart';
import '../../core/image/ico_packer.dart';
import '../../core/image/image_format.dart';
import '../editor/editor_controller.dart';
import '../editor/editor_state.dart';

/// 导出面板（对应 PRD「四、格式转换」「五、图片压缩」）。
///
/// 格式与压缩参数同屏、一次编码生效（PRD 五.6），因此不按功能拆 Tab。
class ExportPage extends ConsumerStatefulWidget {
  const ExportPage({super.key});

  @override
  ConsumerState<ExportPage> createState() => _ExportPageState();
}

class _ExportPageState extends ConsumerState<ExportPage> {
  /// 用户显式选择的格式；null 表示跟随源格式（PRD 九.4）。
  ImageFormat? _chosenFormat;

  /// JPG 质量，默认 85（PRD 九.4）。
  int _quality = 85;

  /// ICO 勾选的尺寸；空集表示尚未选择，按全部可用尺寸处理。
  Set<int> _icoSizes = {};

  EditorController get _controller =>
      ref.read(editorControllerProvider.notifier);

  /// ICO 当前生效的尺寸：可用尺寸 ∩ 用户勾选。
  ///
  /// 交集为空有两种情况：首次进入（未勾选）、换源后原图变小使原有勾选全部
  /// 失效。两者都回落到全部可用尺寸，避免导出 0 个图标。
  Set<int> _effectiveIcoSizes(int width, int height) {
    final available = defaultIcoSizes(width: width, height: height);
    final selected = available.where(_icoSizes.contains).toSet();
    return selected.isEmpty ? available.toSet() : selected;
  }

  void _toggleIcoSize(int size, bool on, Set<int> effective) {
    // 至少保留一个尺寸（PRD 一.4）
    if (!on && effective.length <= 1) return;
    setState(() {
      _icoSizes = {...effective};
      if (on) {
        _icoSizes.add(size);
      } else {
        _icoSizes.remove(size);
      }
    });
  }

  /// 本端可导出的格式：端能力矩阵 ∩ 编码服务实际支持。
  List<ImageFormat> get _allowedFormats {
    final caps = ref.watch(capabilitiesProvider);
    return EncodeService.exportableFormats.where(caps.canExport).toList();
  }

  /// 生效格式：用户选择 > 源格式 > PNG 回退（PRD 九.4）。
  ImageFormat _effectiveFormat(EditorState state, List<ImageFormat> allowed) {
    final chosen = _chosenFormat;
    if (chosen != null && allowed.contains(chosen)) return chosen;
    final source = state.imported?.format;
    if (source != null && allowed.contains(source)) return source;
    return ImageFormat.png;
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(editorControllerProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('导出')),
      body: switch (state.stage) {
        EditorStage.empty => _EmptyView(
          onPick: () => _controller.pickAndLoad(),
        ),
        EditorStage.detecting ||
        EditorStage.decoding ||
        EditorStage.exporting => _BusyView(state: state),
        EditorStage.editable => _buildPanel(state),
        EditorStage.done => _DoneView(
          savedPath: state.exportedPath,
          onContinue: () => _controller.continueEditing(),
          onFinish: () {
            // 结束本次会话：清空状态后一律回首页。
            // 从裁剪页 push 进来时若 pop 回去，会看到一个已清空的裁剪页。
            _controller.reset();
            context.go(AppRoutes.home);
          },
        ),
        _ => _FailureView(
          state: state,
          onRetryImport: () => _controller.pickAndLoad(),
          onBackToPanel: () => _controller.continueEditing(),
          onRetryExport: () => _startExport(state),
        ),
      },
    );
  }

  /// 按当前面板参数发起导出；ICO 需附带勾选的尺寸（PRD 一.4）。
  void _startExport(EditorState state) {
    final target = _effectiveFormat(state, _allowedFormats);
    final decoded = state.decoded;
    final icoSizes = target == ImageFormat.ico && decoded != null
        ? (_effectiveIcoSizes(
            decoded.sourceSize.width,
            decoded.sourceSize.height,
          ).toList()..sort())
        : const <int>[];
    _controller.export(format: target, quality: _quality, icoSizes: icoSizes);
  }

  Widget _buildPanel(EditorState state) {
    final allowed = _allowedFormats;
    final target = _effectiveFormat(state, allowed);
    final imported = state.imported!;
    final sourceFormat = imported.format;
    final size = state.decoded!.sourceSize;
    final icoSelected = target == ImageFormat.ico
        ? _effectiveIcoSizes(size.width, size.height)
        : const <int>{};

    final hints = <String>[
      if (sourceFormat == ImageFormat.webp)
        'WebP 暂不支持导出，已改为 ${target.displayName}（体积可能增大）',
      if (!target.supportsAlpha && (sourceFormat?.supportsAlpha ?? false))
        '${target.displayName} 不支持透明通道，透明区域将填充为白色',
      if (state.hasCrop &&
          state.cropShape == CropShape.circle &&
          !target.supportsAlpha)
        '圆形遮罩的圆外区域在 ${target.displayName} 中会填充为白色',
    ];

    final cropArea = state.crop?.toArea();

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: ListTile(
            leading: const Icon(Icons.image_outlined),
            title: Text(imported.fileName, overflow: TextOverflow.ellipsis),
            subtitle: Text(
              '${sourceFormat?.displayName ?? '未知格式'} · '
              '${size.width}×${size.height} · ${imported.sizeDisplay}',
            ),
          ),
        ),
        // 裁剪状态必须显式告知：从首页直接进导出时，用户未必记得图已被裁过
        if (state.hasCrop && cropArea != null) ...[
          const SizedBox(height: 8),
          Card(
            child: ListTile(
              dense: true,
              leading: Icon(
                state.cropShape == CropShape.circle
                    ? Icons.circle_outlined
                    : Icons.crop,
                size: 20,
              ),
              title: Text(
                '已裁剪 ${cropArea.width} × ${cropArea.height}'
                '${state.cropShape == CropShape.circle ? '（圆形）' : ''}',
              ),
              subtitle: const Text('导出内容为选区范围，非整图'),
              trailing: TextButton(
                onPressed: _controller.resetCrop,
                child: const Text('还原整图'),
              ),
            ),
          ),
        ],
        // 尺寸变更同样要显式告知：用户可能先调尺寸再去裁剪，回来时已忘记
        if (state.hasResize) ...[
          const SizedBox(height: 8),
          Card(
            child: ListTile(
              dense: true,
              leading: const Icon(Icons.photo_size_select_large, size: 20),
              title: Text(
                '已调整为 ${state.resize!.width} × ${state.resize!.height}'
                '（${state.resize!.mode.label}）',
              ),
              subtitle: const Text('导出内容按目标尺寸缩放，非原图分辨率'),
              trailing: TextButton(
                onPressed: _controller.resetResize,
                child: const Text('还原原始尺寸'),
              ),
            ),
          ),
        ],
        const SizedBox(height: 16),
        Text('输出格式', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: [
            for (final format in allowed)
              ChoiceChip(
                label: Text(format.displayName),
                selected: format == target,
                onSelected: (_) => setState(() => _chosenFormat = format),
              ),
          ],
        ),
        if (target == ImageFormat.jpeg) ...[
          const SizedBox(height: 16),
          Row(
            children: [
              Text('质量', style: Theme.of(context).textTheme.titleSmall),
              const Spacer(),
              Text('$_quality'),
            ],
          ),
          Slider(
            value: _quality.toDouble(),
            min: 1,
            max: 100,
            divisions: 99,
            label: '$_quality',
            onChanged: (value) => setState(() => _quality = value.round()),
          ),
        ],
        if (target == ImageFormat.ico)
          _IcoSizeSection(
            width: size.width,
            height: size.height,
            selected: icoSelected,
            onToggle: (option, on) => _toggleIcoSize(option, on, icoSelected),
          ),
        for (final hint in hints) ...[
          const SizedBox(height: 12),
          _HintBar(text: hint),
        ],
        const SizedBox(height: 24),
        FilledButton.icon(
          // 无可生成尺寸时禁用：否则会以「缩小尺寸」的错误文案失败
          onPressed: target == ImageFormat.ico && icoSelected.isEmpty
              ? null
              : () => _startExport(state),
          icon: const Icon(Icons.save_alt),
          label: Text(
            target == ImageFormat.ico
                ? '导出 ICO（${icoSelected.length} 个尺寸）'
                : '导出 ${target.displayName}',
          ),
        ),
      ],
    );
  }
}

/// 参数提示条（透明通道丢失 / WebP 降级，PRD 四.4 / 四.5）。
class _HintBar extends StatelessWidget {
  const _HintBar({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.info_outline,
            size: 18,
            color: scheme.onSecondaryContainer,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(color: scheme.onSecondaryContainer),
            ),
          ),
        ],
      ),
    );
  }
}

/// ICO 尺寸勾选区（PRD 一.4）：默认全选，超过原图较短边的尺寸置灰。
class _IcoSizeSection extends StatelessWidget {
  const _IcoSizeSection({
    required this.width,
    required this.height,
    required this.selected,
    required this.onToggle,
  });

  final int width;
  final int height;
  final Set<int> selected;
  final void Function(int option, bool on) onToggle;

  @override
  Widget build(BuildContext context) {
    final shortEdge = math.min(width, height);
    final available = defaultIcoSizes(width: width, height: height);
    final String note;
    if (available.isEmpty) {
      note = '原图较短边 $shortEdge px，小于最小图标尺寸 16px，无法生成';
    } else if (available.length < icoSizeOptions.length) {
      note = '原图较短边 $shortEdge px，大于该值的尺寸无法生成（已置灰）';
    } else {
      note = '每个尺寸独立重采样，打包为单个 .ico 文件';
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 16),
        Text('图标尺寸', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final option in icoSizeOptions)
              Tooltip(
                message: canRenderIcoSize(option, width: width, height: height)
                    ? '$option×$option'
                    : '原图小于该尺寸，无法生成',
                child: FilterChip(
                  label: Text('$option'),
                  selected: selected.contains(option),
                  onSelected:
                      canRenderIcoSize(option, width: width, height: height)
                      ? (on) => onToggle(option, on)
                      : null,
                ),
              ),
          ],
        ),
        const SizedBox(height: 6),
        Text(note, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}

class _EmptyView extends StatelessWidget {
  const _EmptyView({required this.onPick});

  final VoidCallback onPick;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.image_outlined,
            size: 56,
            color: Theme.of(context).disabledColor,
          ),
          const SizedBox(height: 16),
          const Text('尚未选择图片'),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: onPick,
            icon: const Icon(Icons.file_open),
            label: const Text('选择图片'),
          ),
        ],
      ),
    );
  }
}

class _BusyView extends StatelessWidget {
  const _BusyView({required this.state});

  final EditorState state;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(width: 240, child: LinearProgressIndicator()),
          const SizedBox(height: 16),
          Text(state.phase.label),
        ],
      ),
    );
  }
}

class _DoneView extends StatelessWidget {
  const _DoneView({
    required this.savedPath,
    required this.onContinue,
    required this.onFinish,
  });

  final String? savedPath;
  final VoidCallback onContinue;
  final VoidCallback onFinish;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.check_circle_outline, size: 56, color: scheme.primary),
            const SizedBox(height: 16),
            const Text('导出完成'),
            if (savedPath != null) ...[
              const SizedBox(height: 8),
              Text(
                savedPath!,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            const SizedBox(height: 24),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                OutlinedButton(
                  onPressed: onContinue,
                  child: const Text('继续编辑'),
                ),
                const SizedBox(width: 12),
                FilledButton(onPressed: onFinish, child: const Text('完成')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _FailureView extends StatelessWidget {
  const _FailureView({
    required this.state,
    required this.onRetryImport,
    required this.onRetryExport,
    required this.onBackToPanel,
  });

  final EditorState state;
  final VoidCallback onRetryImport;
  final VoidCallback onRetryExport;
  final VoidCallback onBackToPanel;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final failure = state.failure;
    final isExportError = failure?.code.isExportError ?? false;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 48, color: scheme.error),
            const SizedBox(height: 16),
            Text(
              failure?.code.code ?? AppErrorCode.corruptedFile.code,
              style: TextStyle(color: scheme.error),
            ),
            const SizedBox(height: 8),
            Text(
              failure?.message ?? AppErrorCode.corruptedFile.userMessage,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                OutlinedButton(
                  onPressed: isExportError ? onBackToPanel : onRetryImport,
                  child: Text(isExportError ? '返回修改' : '重新选择'),
                ),
                if (isExportError) ...[
                  const SizedBox(width: 12),
                  FilledButton(
                    onPressed: onRetryExport,
                    child: const Text('重试'),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}
