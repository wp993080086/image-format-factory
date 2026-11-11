import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/router.dart';
import '../../core/error/app_error.dart';
import '../../core/image/image_header_probe.dart';
import '../../core/image/resize_geometry.dart';
import '../editor/editor_controller.dart';
import '../editor/editor_state.dart';

/// 尺寸与比例变换页（对应 PRD「三、尺寸与比例变换」）。
///
/// 宽高以**原图像素**输入，超出双上限时由模型钳制并提示（PRD 三.1）；
/// 预览按目标宽高比渲染，用 `BoxFit` 直接表达三种填充模式。
class ResizePage extends ConsumerWidget {
  const ResizePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(editorControllerProvider);
    void onPick() => ref.read(editorControllerProvider.notifier).pickAndLoad();
    return Scaffold(
      appBar: AppBar(title: const Text('尺寸与比例')),
      body: switch (state.stage) {
        EditorStage.empty => _EmptyView(onPick: onPick),
        EditorStage.detecting ||
        EditorStage.decoding => _BusyView(state: state),
        EditorStage.editable => _ResizeEditor(state: state),
        _ => _FailureView(state: state, onPick: onPick),
      },
    );
  }
}

class _ResizeEditor extends ConsumerStatefulWidget {
  const _ResizeEditor({required this.state});

  final EditorState state;

  @override
  ConsumerState<_ResizeEditor> createState() => _ResizeEditorState();
}

class _ResizeEditorState extends ConsumerState<_ResizeEditor> {
  final _widthCtrl = TextEditingController();
  final _heightCtrl = TextEditingController();
  final _widthFocus = FocusNode();
  final _heightFocus = FocusNode();

  /// 锁定原图宽高比：改一边自动算另一边。
  bool _lockRatio = true;

  /// 锁定用的宽高比，锁定时取原图比，重新锁定时取当前输入比。
  double _ratio = 1;

  late ResizeMode _mode;
  late int _background;

  EditorController get _controller =>
      ref.read(editorControllerProvider.notifier);

  ImageDimensions get _sourceSize => widget.state.decoded!.sourceSize;

  /// 当前目标：优先取已生效的变换，否则与原图一致。
  ResizeTarget get _target =>
      widget.state.resize ??
      ResizeTarget(width: _sourceSize.width, height: _sourceSize.height);

  @override
  void initState() {
    super.initState();
    final size = _sourceSize;
    _ratio = size.width / size.height;
    _mode = widget.state.resize?.mode ?? ResizeMode.stretch;
    _background =
        widget.state.resize?.backgroundArgb ??
        ResizeTarget.transparentBackground;
    _syncFields(_target.width, _target.height);
  }

  @override
  void dispose() {
    _widthCtrl.dispose();
    _heightCtrl.dispose();
    _widthFocus.dispose();
    _heightFocus.dispose();
    super.dispose();
  }

  /// 同步输入框；[force] 用于提交后修正被钳制的值（此时焦点可能仍在框内）。
  void _syncFields(int width, int height, {bool force = false}) {
    if (force || !_widthFocus.hasFocus) _widthCtrl.text = '$width';
    if (force || !_heightFocus.hasFocus) _heightCtrl.text = '$height';
  }

  /// 提交输入：钳制后写回状态，并把输入框修正为实际生效值。
  void _apply() {
    final w = int.tryParse(_widthCtrl.text);
    final h = int.tryParse(_heightCtrl.text);
    if (w == null || h == null || w <= 0 || h <= 0) {
      final target = _target;
      _syncFields(target.width, target.height, force: true);
      return;
    }
    final clamp = _controller.updateResize(
      width: w,
      height: h,
      mode: _mode,
      backgroundArgb: _background,
    );
    if (clamp == null) return;
    // 钳制后立刻把输入框改成实际生效值，避免界面显示一个不会生效的数字
    _syncFields(clamp.width, clamp.height, force: true);
  }

  /// 改宽时按锁定比例联动高度；只在文本层联动，失焦时统一提交。
  void _onWidthChanged(String value) {
    final w = int.tryParse(value);
    if (!_lockRatio || w == null || w <= 0) return;
    final maxHeight = _sourceSize.height * maxResizeUpscale;
    _heightCtrl.text = '${(w / _ratio).round().clamp(1, maxHeight)}';
  }

  void _onHeightChanged(String value) {
    final h = int.tryParse(value);
    if (!_lockRatio || h == null || h <= 0) return;
    final maxWidth = _sourceSize.width * maxResizeUpscale;
    _widthCtrl.text = '${(h * _ratio).round().clamp(1, maxWidth)}';
  }

  void _toggleLock() {
    setState(() {
      _lockRatio = !_lockRatio;
      if (_lockRatio) {
        final w = int.tryParse(_widthCtrl.text);
        final h = int.tryParse(_heightCtrl.text);
        if (w != null && h != null && w > 0 && h > 0) _ratio = w / h;
      }
    });
  }

  void _setMode(ResizeMode mode) {
    setState(() => _mode = mode);
    _apply();
  }

  void _setBackground(int argb) {
    setState(() => _background = argb);
    _apply();
  }

  void _goExport() {
    // 点按钮前可能仍有未提交的输入（移动端尤其如此）
    _apply();
    context.push(AppRoutes.exportPanel);
  }

  @override
  Widget build(BuildContext context) {
    final target = _target;
    return Column(
      children: [
        Expanded(child: _buildPreview(target)),
        _buildPanel(target),
      ],
    );
  }

  Widget _buildPreview(ResizeTarget target) {
    final aspect = (target.width / target.height).clamp(0.05, 20.0);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: AspectRatio(
          aspectRatio: aspect,
          child: ClipRect(
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (target.isTransparent)
                  const CustomPaint(painter: _CheckerboardPainter())
                else
                  ColoredBox(color: Color(target.backgroundArgb)),
                Image.memory(
                  widget.state.decoded!.previewPng,
                  fit: switch (target.mode) {
                    ResizeMode.stretch => BoxFit.fill,
                    ResizeMode.cover => BoxFit.cover,
                    ResizeMode.contain => BoxFit.contain,
                  },
                  filterQuality: FilterQuality.medium,
                  gaplessPlayback: true,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPanel(ResizeTarget target) {
    final theme = Theme.of(context);
    final source = _sourceSize;
    // 提示按「当前目标是否触顶」推导，而不是记录一次钳制事件：
    // 提交会被失焦与回车各触发一次，事件式的提示会在第二次合法提交时被清掉。
    final atEdgeLimit =
        target.width >= source.width * maxResizeUpscale ||
        target.height >= source.height * maxResizeUpscale;
    final atPixelLimit = target.width * target.height >= maxResizePixels;
    final hints = <String>[
      if (atEdgeLimit) '已达单边放大上限（原图的 $maxResizeUpscale 倍）',
      if (atPixelLimit) '已达总像素上限（${maxResizePixels ~/ 10000} 万）',
      if (target.width > source.width || target.height > source.height)
        '目标尺寸大于原图，属于放大，画质会变软',
    ];

    return Material(
      elevation: 2,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: SegmentedButton<ResizeMode>(
                      segments: [
                        for (final mode in ResizeMode.values)
                          ButtonSegment(value: mode, label: Text(mode.label)),
                      ],
                      selected: {_mode},
                      onSelectionChanged: (value) => _setMode(value.first),
                      showSelectedIcon: false,
                      style: const ButtonStyle(
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(_mode.description, style: theme.textTheme.bodySmall),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: Focus(
                      focusNode: _widthFocus,
                      onFocusChange: (focused) {
                        if (!focused) _apply();
                      },
                      child: TextField(
                        controller: _widthCtrl,
                        decoration: const InputDecoration(
                          labelText: '宽（px）',
                          isDense: true,
                          border: OutlineInputBorder(),
                        ),
                        keyboardType: TextInputType.number,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                        ],
                        onChanged: _onWidthChanged,
                        onSubmitted: (_) => _apply(),
                      ),
                    ),
                  ),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 8),
                    child: Text('×'),
                  ),
                  Expanded(
                    child: Focus(
                      focusNode: _heightFocus,
                      onFocusChange: (focused) {
                        if (!focused) _apply();
                      },
                      child: TextField(
                        controller: _heightCtrl,
                        decoration: const InputDecoration(
                          labelText: '高（px）',
                          isDense: true,
                          border: OutlineInputBorder(),
                        ),
                        keyboardType: TextInputType.number,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                        ],
                        onChanged: _onHeightChanged,
                        onSubmitted: (_) => _apply(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Tooltip(
                    message: _lockRatio ? '已锁定宽高比' : '锁定宽高比',
                    child: IconButton(
                      onPressed: _toggleLock,
                      isSelected: _lockRatio,
                      icon: const Icon(Icons.link),
                      selectedIcon: const Icon(Icons.link),
                      color: _lockRatio
                          ? theme.colorScheme.primary
                          : theme.disabledColor,
                    ),
                  ),
                  Tooltip(
                    message: '还原原始尺寸',
                    child: IconButton(
                      onPressed: () {
                        _controller.resetResize();
                        _syncFields(source.width, source.height, force: true);
                      },
                      icon: const Icon(Icons.restart_alt),
                    ),
                  ),
                ],
              ),
              if (_mode == ResizeMode.contain) ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final entry in resizeBackgrounds.entries)
                      ChoiceChip(
                        label: Text(entry.key),
                        visualDensity: VisualDensity.compact,
                        selected:
                            _background ==
                            (entry.value ?? ResizeTarget.transparentBackground),
                        onSelected: (_) => _setBackground(
                          entry.value ?? ResizeTarget.transparentBackground,
                        ),
                      ),
                  ],
                ),
              ],
              const SizedBox(height: 8),
              Text(
                '原图 ${source.width} × ${source.height}'
                ' → 目标 ${target.width} × ${target.height}'
                ' · ${scaleLabel(source, target.width, target.height)}',
                style: theme.textTheme.bodySmall,
              ),
              for (final hint in hints)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    hint,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _goExport,
                  icon: const Icon(Icons.arrow_forward),
                  label: const Text('下一步：导出'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 透明区域的棋盘格底，避免用户误以为是白色留白。
class _CheckerboardPainter extends CustomPainter {
  const _CheckerboardPainter();

  static const _cell = 10.0;
  static const _light = Color(0xFFFFFFFF);
  static const _dark = Color(0xFFE6E6E6);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = _light);
    final paint = Paint()..color = _dark;
    final cols = (size.width / _cell).ceil();
    final rows = (size.height / _cell).ceil();
    for (var y = 0; y < rows; y++) {
      for (var x = 0; x < cols; x++) {
        if ((x + y).isEven) continue;
        canvas.drawRect(
          Rect.fromLTWH(x * _cell, y * _cell, _cell, _cell),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_CheckerboardPainter old) => false;
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

class _FailureView extends StatelessWidget {
  const _FailureView({required this.state, required this.onPick});

  final EditorState state;
  final VoidCallback onPick;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final failure = state.failure;
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
            FilledButton(onPressed: onPick, child: const Text('重新选择')),
          ],
        ),
      ),
    );
  }
}
