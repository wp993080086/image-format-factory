import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/router.dart';
import '../../core/di/providers.dart';
import '../../core/error/app_error.dart';
import '../../core/image/crop_selection.dart';
import '../../core/image/encode_service.dart';
import '../../core/image/ico_packer.dart';
import '../../core/image/image_format.dart';
import '../../core/image/image_header_probe.dart';
import '../../services/file/export_service.dart';
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

  /// JPG 色度抽样，默认 4:2:0（PRD 五.1）。
  JpegChromaOption _jpegChroma = JpegChromaOption.yuv420;

  /// PNG 压缩级别，默认 6（PRD 九.4）。
  int _pngLevel = 6;

  /// PNG 调色板压缩（PNG8），默认关（PRD 五.2）。
  bool _pngPalette = false;

  /// 预估输出体积（字节）；null 表示未算出或该格式不预估（ICO）。
  int? _estimate;
  bool _estimating = false;

  /// 参数变化后的 debounce 计时器（PRD 四.7：300ms）。
  Timer? _estimateTimer;

  /// 首次进入面板时触发一次预估，避免每次 build 重复调度。
  bool _estimateRequested = false;

  @override
  void dispose() {
    _estimateTimer?.cancel();
    super.dispose();
  }

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
        EditorStage.editable => _withShortcuts(_buildPanel(state), state),
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

  /// 最终输出的像素尺寸：缩放优先，其次裁剪，最后原图（PRD 四.7）。
  ImageDimensions _outputSize(EditorState state) {
    final decoded = state.decoded;
    if (decoded == null) return const ImageDimensions(0, 0);
    if (state.hasResize) {
      return ImageDimensions(state.resize!.width, state.resize!.height);
    }
    if (state.hasCrop) {
      final area = state.crop!.toArea();
      return ImageDimensions(area.width, area.height);
    }
    return decoded.sourceSize;
  }

  /// 参数变化后延迟 300ms 再算，避免拖动滑块时连续编码（PRD 四.7）。
  void _scheduleEstimate() {
    _estimateTimer?.cancel();
    _estimateTimer = Timer(const Duration(milliseconds: 300), _runEstimate);
  }

  Future<void> _runEstimate() async {
    if (!mounted) return;
    final state = ref.read(editorControllerProvider);
    final decoded = state.decoded;
    if (decoded == null) return;
    final target = _effectiveFormat(state, _allowedFormats);
    if (target == ImageFormat.ico) {
      setState(() {
        _estimate = null;
        _estimating = false;
      });
      return;
    }
    setState(() => _estimating = true);
    try {
      final bytes = await ref
          .read(encodeServiceProvider)
          .estimate(
            EstimateRequest(
              previewPng: decoded.previewPng,
              outputSize: _outputSize(state),
              format: target,
              quality: _quality,
              jpegChroma: _jpegChroma,
              pngLevel: _pngLevel,
              pngPalette: _pngPalette,
              blur: state.blur,
            ),
          );
      if (!mounted) return;
      setState(() {
        _estimate = bytes;
        _estimating = false;
      });
    } catch (_) {
      // 预估失败不影响导出，静默隐藏即可
      if (!mounted) return;
      setState(() => _estimating = false);
    }
  }

  /// Ctrl/Cmd+S 直接导出（PRD 九.6）。
  ///
  /// 面板内没有常驻输入焦点，所以挂一个 autofocus 的 [Focus]，
  /// 否则刚进面板时按键无人接收。
  Widget _withShortcuts(Widget child, EditorState state) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyS, control: true): () =>
            _exportIfReady(state),
        const SingleActivator(LogicalKeyboardKey.keyS, meta: true): () =>
            _exportIfReady(state),
      },
      child: Focus(autofocus: true, child: child),
    );
  }

  /// 快捷键入口：与导出按钮保持同样的可用性判断。
  void _exportIfReady(EditorState state) {
    final target = _effectiveFormat(state, _allowedFormats);
    final decoded = state.decoded;
    if (target == ImageFormat.ico && decoded != null) {
      // 原图小于最小图标尺寸时一个尺寸也生成不出来，直接忽略
      if (_effectiveIcoSizes(
        decoded.sourceSize.width,
        decoded.sourceSize.height,
      ).isEmpty) {
        return;
      }
    }
    _startExport(state);
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
    _controller.export(
      format: target,
      quality: _quality,
      icoSizes: icoSizes,
      jpegChroma: _jpegChroma,
      pngLevel: _pngLevel,
      pngPalette: _pngPalette,
    );
  }

  /// 质量滑块：JPEG 与 WebP 共用同一套参数语义（1–100）。
  Widget _qualityControl() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
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
          onChanged: (value) {
            setState(() => _quality = value.round());
            _scheduleEstimate();
          },
        ),
      ],
    );
  }

  Widget _buildPanel(EditorState state) {
    // 首次渲染后立即预估一次；之后的参数变化走 300ms debounce
    if (!_estimateRequested) {
      _estimateRequested = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _runEstimate());
    }
    final allowed = _allowedFormats;
    final target = _effectiveFormat(state, allowed);
    final imported = state.imported!;
    final sourceFormat = imported.format;
    final size = state.decoded!.sourceSize;
    final icoSelected = target == ImageFormat.ico
        ? _effectiveIcoSizes(size.width, size.height)
        : const <int>{};

    final hints = <String>[
      if (sourceFormat == ImageFormat.webp &&
          target != ImageFormat.webp &&
          _chosenFormat == null)
        '本端暂不支持导出 WebP，已改为 ${target.displayName}（体积可能增大）',
      if (!target.supportsAlpha && (sourceFormat?.supportsAlpha ?? false))
        '${target.displayName} 不支持透明通道，透明区域将填充为白色',
      if (state.hasCrop &&
          state.cropShape == CropShape.circle &&
          !target.supportsAlpha)
        '圆形遮罩的圆外区域在 ${target.displayName} 中会填充为白色',
    ];

    final cropArea = state.crop?.toArea();
    final hasSemiTransparent = state.decoded!.hasSemiTransparent;

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
                onSelected: (_) {
                  setState(() => _chosenFormat = format);
                  _scheduleEstimate();
                },
              ),
          ],
        ),
        if (target == ImageFormat.jpeg) ...[
          const SizedBox(height: 16),
          _qualityControl(),
          const SizedBox(height: 4),
          Text('色度抽样', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 6),
          SegmentedButton<JpegChromaOption>(
            segments: [
              for (final option in JpegChromaOption.values)
                ButtonSegment(value: option, label: Text(option.label)),
            ],
            selected: {_jpegChroma},
            onSelectionChanged: (value) {
              setState(() => _jpegChroma = value.first);
              _scheduleEstimate();
            },
            showSelectedIcon: false,
            style: const ButtonStyle(visualDensity: VisualDensity.compact),
          ),
          const SizedBox(height: 4),
          Text(
            _jpegChroma.description,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
        if (target == ImageFormat.webp) ...[
          const SizedBox(height: 16),
          _qualityControl(),
          const SizedBox(height: 4),
          Text(
            'WebP 质量参数与 JPEG 一致：1 体积最小，100 画质最好；'
            '支持透明通道，同画质下通常比 JPEG 小',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
        if (target == ImageFormat.png) ...[
          const SizedBox(height: 16),
          Row(
            children: [
              Text('压缩级别', style: Theme.of(context).textTheme.titleSmall),
              const Spacer(),
              Text('$_pngLevel'),
            ],
          ),
          Slider(
            value: _pngLevel.toDouble(),
            min: 0,
            max: 9,
            divisions: 9,
            label: '$_pngLevel',
            onChanged: (value) {
              setState(() => _pngLevel = value.round());
              _scheduleEstimate();
            },
          ),
          Text(
            '0 = 不压缩最快，9 = 最高压缩最慢；无损，不影响画质',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            value: _pngPalette && !hasSemiTransparent,
            onChanged: hasSemiTransparent
                ? null
                : (value) {
                    setState(() => _pngPalette = value);
                    _scheduleEstimate();
                  },
            title: const Text('调色板压缩（PNG8）'),
            subtitle: Text(
              hasSemiTransparent
                  ? '源图含半透明像素，PNG8 会把半透明压成硬边，已禁用'
                  : '最多 256 色，有损，体积显著减小',
            ),
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
        const SizedBox(height: 16),
        _EstimateBar(
          estimate: _estimate,
          estimating: _estimating,
          sourceBytes: imported.bytes.length,
        ),
        const SizedBox(height: 8),
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

/// 体积预估条（PRD 四.7）：按 512px 采样外推，小体积时误差偏大，需标注。
class _EstimateBar extends StatelessWidget {
  const _EstimateBar({
    required this.estimate,
    required this.estimating,
    required this.sourceBytes,
  });

  final int? estimate;
  final bool estimating;
  final int sourceBytes;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // ICO 不预估，整块隐藏；计算中保留标题，避免布局在出现/消失之间跳动
    if (!estimating && estimate == null) return const SizedBox.shrink();

    if (estimating) {
      // 刻意不用无限旋转的进度指示器：估算常在参数微调时反复触发，
      // 转圈反而比一行文字更打扰；也让组件测试能正常 settle。
      return Row(
        children: [
          Text('预估体积', style: theme.textTheme.titleSmall),
          const Spacer(),
          Text('计算中…', style: theme.textTheme.bodySmall),
        ],
      );
    }

    final value = estimate!;
    final String ratio;
    if (sourceBytes > 0) {
      final delta = (value - sourceBytes) / sourceBytes;
      final percent = (delta.abs() * 100).round();
      ratio = delta <= 0 ? '压缩 $percent%' : '增大 $percent%';
    } else {
      ratio = '';
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('预估体积', style: theme.textTheme.titleSmall),
            const Spacer(),
            Text('约 ${formatBytes(value)}'),
          ],
        ),
        const SizedBox(height: 2),
        Text(
          [
            '源文件 ${formatBytes(sourceBytes)}',
            if (ratio.isNotEmpty) ratio,
            // 采样外推在高压缩比的小图上误差最大，按 PRD 四.7 加注
            if (value < 50 * 1024) '小体积误差较大',
          ].join(' · '),
          style: theme.textTheme.bodySmall,
        ),
      ],
    );
  }
}

/// 字节数的人类可读格式。
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
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
        // 多尺寸 ICO 用看图软件打开通常只显示一张——那是查看器的行为，
        // 文件里确实写入了全部尺寸。不说明清楚会被当成导出失败。
        if (selected.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            '看图软件打开 .ico 通常只显示其中一张，这是查看器的行为；'
            '文件内已写入 ${selected.length} 个尺寸。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
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
                displaySavedPath(savedPath),
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
