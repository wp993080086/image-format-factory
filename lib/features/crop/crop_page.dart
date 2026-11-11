import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/router.dart';
import '../../core/error/app_error.dart';
import '../../core/image/crop_selection.dart';
import '../../core/image/image_header_probe.dart';
import '../editor/editor_controller.dart';
import '../editor/editor_state.dart';

/// 裁剪页（对应 PRD「二、裁剪功能」）。
///
/// 选区定义在**原图坐标系**（PRD 二.5），视图缩放/平移只影响显示；
/// 导出时把整数选区交给编码服务，在全分辨率位图上直接拷贝像素。
class CropPage extends ConsumerWidget {
  const CropPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(editorControllerProvider);
    void onPick() => ref.read(editorControllerProvider.notifier).pickAndLoad();
    return Scaffold(
      appBar: AppBar(title: const Text('裁剪')),
      body: switch (state.stage) {
        EditorStage.empty => _EmptyView(onPick: onPick),
        EditorStage.detecting ||
        EditorStage.decoding => _BusyView(state: state),
        EditorStage.editable => _CropEditor(state: state),
        _ => _FailureView(state: state, onPick: onPick),
      },
    );
  }
}

/// 画布上的手势归属。
enum _DragMode {
  /// 无（手势未落在任何可拖区域）。
  none,

  /// 视图缩放/平移。
  view,

  /// 拖拽选区内：整体平移选区。
  move,

  /// 拖拽手柄：调整选区大小。
  resize,
}

/// 可编辑态：画布 + 参数面板。
class _CropEditor extends ConsumerStatefulWidget {
  const _CropEditor({required this.state});

  final EditorState state;

  @override
  ConsumerState<_CropEditor> createState() => _CropEditorState();
}

class _CropEditorState extends ConsumerState<_CropEditor> {
  static const _maxScale = 8.0;

  /// 手柄命中半径（屏幕像素），触控与鼠标取同一值。
  static const _handleHitRadius = 16.0;

  /// 视图缩放与平移。
  double _scale = 1;
  Offset _offset = Offset.zero;

  _DragMode _mode = _DragMode.none;
  CropHandle? _handle;
  CropSelection? _startSelection;
  Offset _startLocal = Offset.zero;
  double _startScale = 1;
  Offset _startOffset = Offset.zero;
  Offset? _zoomAnchor;

  final _widthCtrl = TextEditingController();
  final _heightCtrl = TextEditingController();
  final _widthFocus = FocusNode();
  final _heightFocus = FocusNode();

  EditorController get _controller =>
      ref.read(editorControllerProvider.notifier);

  ImageDimensions get _sourceSize => widget.state.decoded!.sourceSize;

  /// 当前生效的比例：圆形强制 1:1（PRD 二.2）。
  double? get _lockedRatio => widget.state.cropShape == CropShape.circle
      ? 1.0
      : widget.state.cropAspect.ratio;

  @override
  void initState() {
    super.initState();
    final selection = widget.state.crop;
    if (selection != null) _syncSizeFields(selection);
  }

  @override
  void dispose() {
    _widthCtrl.dispose();
    _heightCtrl.dispose();
    _widthFocus.dispose();
    _heightFocus.dispose();
    super.dispose();
  }

  /// 把选区尺寸同步到输入框；正在编辑的框不覆盖，避免光标被夺。
  void _syncSizeFields(CropSelection selection) {
    final area = selection.toArea();
    if (!_widthFocus.hasFocus && _widthCtrl.text != '${area.width}') {
      _widthCtrl.text = '${area.width}';
    }
    if (!_heightFocus.hasFocus && _heightCtrl.text != '${area.height}') {
      _heightCtrl.text = '${area.height}';
    }
  }

  /// 提交目标尺寸：以原图像素为准，超限由模型钳制（PRD 二.3）。
  void _applyTargetSize() {
    final w = int.tryParse(_widthCtrl.text);
    final h = int.tryParse(_heightCtrl.text);
    if (w == null || h == null || w <= 0 || h <= 0) {
      final selection = ref.read(editorControllerProvider).crop;
      if (selection != null) _syncSizeFields(selection);
      return;
    }
    _controller.setCropTargetSize(w, h);
  }

  /// 比例锁定时宽高联动，只改文本，选区在提交时统一应用。
  void _onWidthChanged(String value) {
    final ratio = _lockedRatio;
    final w = int.tryParse(value);
    if (ratio == null || w == null || w <= 0) return;
    _heightCtrl.text = '${math.max(1, (w / ratio).round())}';
  }

  void _onHeightChanged(String value) {
    final ratio = _lockedRatio;
    final h = int.tryParse(value);
    if (ratio == null || h == null || h <= 0) return;
    _widthCtrl.text = '${math.max(1, (h * ratio).round())}';
  }

  // ---------- 视图变换 ----------

  /// 围绕容器中心缩放、再整体平移的变换矩阵。
  Matrix4 _viewMatrix(Size box) {
    final center = Offset(box.width / 2, box.height / 2);
    return Matrix4.translationValues(_offset.dx, _offset.dy, 0)
      ..multiply(Matrix4.translationValues(center.dx, center.dy, 0))
      ..multiply(Matrix4.diagonal3Values(_scale, _scale, 1))
      ..multiply(Matrix4.translationValues(-center.dx, -center.dy, 0));
  }

  /// 屏幕坐标 → 画布坐标（未应用视图变换的坐标系）。
  Offset _toCanvas(Offset local, Size box) =>
      MatrixUtils.transformPoint(Matrix4.inverted(_viewMatrix(box)), local);

  /// 屏幕坐标 → 原图坐标。
  Offset _toOrigin(Offset local, Size box) {
    final canvas = _toCanvas(local, box);
    final fit = _fitSize(_sourceSize, box);
    final origin = Offset(
      (box.width - fit.width) / 2,
      (box.height - fit.height) / 2,
    );
    return Offset(
      (canvas.dx - origin.dx) * _sourceSize.width / fit.width,
      (canvas.dy - origin.dy) * _sourceSize.height / fit.height,
    );
  }

  /// 图片按 contain 适配容器后的显示尺寸。
  Size _fitSize(ImageDimensions source, Size box) {
    final imageAspect = source.width / source.height;
    final boxAspect = box.width / box.height;
    if (imageAspect > boxAspect) {
      return Size(box.width, box.width / imageAspect);
    }
    return Size(box.height * imageAspect, box.height);
  }

  /// 原图坐标 → 容器坐标，供绘制使用。
  Rect _selectionRect(CropSelection selection, Size box) {
    final fit = _fitSize(_sourceSize, box);
    final origin = Offset(
      (box.width - fit.width) / 2,
      (box.height - fit.height) / 2,
    );
    return Rect.fromLTWH(
      origin.dx + selection.left * fit.width / _sourceSize.width,
      origin.dy + selection.top * fit.height / _sourceSize.height,
      selection.width * fit.width / _sourceSize.width,
      selection.height * fit.height / _sourceSize.height,
    );
  }

  /// 命中测试：手柄 > 选区内 > 选区外（PRD 手势分工，选区内拖=移动）。
  ({_DragMode mode, CropHandle? handle}) _hitTest(Offset local, Size box) {
    final selection = widget.state.crop;
    if (selection == null) return (mode: _DragMode.view, handle: null);
    final canvas = _toCanvas(local, box);
    final rect = _selectionRect(selection, box);
    // 屏幕阈值换算到画布坐标
    final threshold = _handleHitRadius / _scale;

    for (final entry in _handlePositions(
      rect,
      widget.state.cropShape,
    ).entries) {
      if ((canvas - entry.value).distance <= threshold) {
        return (mode: _DragMode.resize, handle: entry.key);
      }
    }

    // 选区贴满整图时已经无处可移，此时拖动降级为视图平移，
    // 否则用户会得到「拖了但什么都没发生」的死手感。
    final movable =
        selection.width < _sourceSize.width - 0.5 ||
        selection.height < _sourceSize.height - 0.5;
    if (movable && rect.inflate(threshold / 2).contains(canvas)) {
      return (mode: _DragMode.move, handle: null);
    }
    return (mode: _DragMode.view, handle: null);
  }

  // ---------- 手势 ----------

  void _onScaleStart(ScaleStartDetails d, Size box) {
    _startScale = _scale;
    _startOffset = _offset;
    _startLocal = d.localFocalPoint;
    if (d.pointerCount >= 2) {
      _mode = _DragMode.view;
      _zoomAnchor = _toCanvas(d.localFocalPoint, box);
      return;
    }
    // 双指抬起变单指时手势会重新 start，必须清掉旧锚点，
    // 否则后续单指拖动会用过期锚点算出一次跳变
    _zoomAnchor = null;
    final hit = _hitTest(d.localFocalPoint, box);
    _mode = hit.mode;
    _handle = hit.handle;
    _startSelection = widget.state.crop;
  }

  void _onScaleUpdate(ScaleUpdateDetails d, Size box) {
    if (d.pointerCount >= 2 && _zoomAnchor != null) {
      _applyZoom(d, box);
      return;
    }
    switch (_mode) {
      case _DragMode.move:
        final delta =
            _toOrigin(d.localFocalPoint, box) - _toOrigin(_startLocal, box);
        final moved = _startSelection?.moved(delta.dx, delta.dy, _sourceSize);
        if (moved != null) _controller.updateCrop(moved);
      case _DragMode.resize:
        final handle = _handle;
        if (handle == null) return;
        final delta =
            _toOrigin(d.localFocalPoint, box) - _toOrigin(_startLocal, box);
        final resized = _startSelection?.resized(
          handle,
          delta.dx,
          delta.dy,
          _sourceSize,
          widget.state.cropAspect,
          widget.state.cropShape,
        );
        if (resized != null) _controller.updateCrop(resized);
      case _DragMode.view:
        // 双指缩放与非双指平移都走这里
        if (_zoomAnchor != null) {
          _applyZoom(d, box);
        } else {
          setState(() {
            _offset = _startOffset + (d.localFocalPoint - _startLocal);
          });
        }
      case _DragMode.none:
        break;
    }
  }

  /// 以双指/滚轮落点为锚点缩放，保证锚点下的画布内容不漂移。
  void _applyZoom(ScaleUpdateDetails d, Size box) {
    final anchor = _zoomAnchor;
    if (anchor == null) return;
    final newScale = (_startScale * d.scale).clamp(1.0, _maxScale);
    final center = Offset(box.width / 2, box.height / 2);
    final local = d.localFocalPoint;
    setState(() {
      _scale = newScale;
      _offset = Offset(
        local.dx - center.dx - (anchor.dx - center.dx) * newScale,
        local.dy - center.dy - (anchor.dy - center.dy) * newScale,
      );
    });
  }

  void _onScaleEnd(ScaleEndDetails d) {
    _mode = _DragMode.none;
    _handle = null;
    _startSelection = null;
    _zoomAnchor = null;
  }

  /// 滚轮缩放（桌面端），以指针位置为锚点。
  void _onPointerSignal(PointerSignalEvent event, Size box) {
    if (event is! PointerScrollEvent) return;
    final factor = event.scrollDelta.dy > 0 ? 0.9 : 1.1;
    final newScale = (_scale * factor).clamp(1.0, _maxScale);
    final anchor = _toCanvas(event.localPosition, box);
    final center = Offset(box.width / 2, box.height / 2);
    final local = event.localPosition;
    setState(() {
      _scale = newScale;
      _offset = Offset(
        local.dx - center.dx - (anchor.dx - center.dx) * newScale,
        local.dy - center.dy - (anchor.dy - center.dy) * newScale,
      );
    });
  }

  void _resetView() => setState(() {
    _scale = 1;
    _offset = Offset.zero;
  });

  @override
  Widget build(BuildContext context) {
    final selection = widget.state.crop;
    if (selection == null) return const SizedBox.shrink();

    // 选区被外部（输入框、比例切换）改动后同步尺寸输入框
    ref.listen(editorControllerProvider, (previous, next) {
      final crop = next.crop;
      if (crop != null) _syncSizeFields(crop);
    });

    return Column(
      children: [
        Expanded(child: _buildCanvas(selection)),
        _buildPanel(selection),
      ],
    );
  }

  Widget _buildCanvas(CropSelection selection) {
    final source = _sourceSize;
    return LayoutBuilder(
      builder: (context, constraints) {
        final box = Size(constraints.maxWidth, constraints.maxHeight);
        if (box.isEmpty) return const SizedBox.shrink();
        final fit = _fitSize(source, box);
        final origin = Offset(
          (box.width - fit.width) / 2,
          (box.height - fit.height) / 2,
        );
        return Listener(
          onPointerSignal: (e) => _onPointerSignal(e, box),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onScaleStart: (d) => _onScaleStart(d, box),
            onScaleUpdate: (d) => _onScaleUpdate(d, box),
            onScaleEnd: _onScaleEnd,
            child: ClipRect(
              child: Stack(
                children: [
                  Transform(
                    transform: _viewMatrix(box),
                    child: Stack(
                      children: [
                        Positioned(
                          left: origin.dx,
                          top: origin.dy,
                          width: fit.width,
                          height: fit.height,
                          child: Image.memory(
                            widget.state.decoded!.previewPng,
                            fit: BoxFit.fill,
                            filterQuality: FilterQuality.medium,
                            gaplessPlayback: true,
                          ),
                        ),
                        Positioned.fill(
                          child: IgnorePointer(
                            child: CustomPaint(
                              painter: _SelectionPainter(
                                selection: selection,
                                shape: widget.state.cropShape,
                                source: source,
                                fit: fit,
                                origin: origin,
                                scale: _scale,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (_scale > 1.01)
                    Positioned(
                      right: 8,
                      bottom: 8,
                      child: Tooltip(
                        message: '缩放至适配',
                        child: IconButton.filledTonal(
                          onPressed: _resetView,
                          icon: const Icon(Icons.fit_screen, size: 18),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildPanel(CropSelection selection) {
    final theme = Theme.of(context);
    final state = widget.state;
    final area = selection.toArea();
    final source = _sourceSize;

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
                  SegmentedButton<CropShape>(
                    segments: [
                      for (final shape in CropShape.values)
                        ButtonSegment(value: shape, label: Text(shape.label)),
                    ],
                    selected: {state.cropShape},
                    onSelectionChanged: (value) =>
                        _controller.updateCropShape(value.first),
                    showSelectedIcon: false,
                    style: const ButtonStyle(
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '${area.width} × ${area.height}',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (final aspect in CropAspect.values) ...[
                      _AspectChip(
                        aspect: aspect,
                        selected: state.cropAspect == aspect,
                        enabled: aspect.allowedFor(state.cropShape),
                        onTap: () => _controller.updateCropAspect(aspect),
                      ),
                      const SizedBox(width: 6),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: Focus(
                      focusNode: _widthFocus,
                      onFocusChange: (focused) {
                        if (!focused) _applyTargetSize();
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
                        onSubmitted: (_) => _applyTargetSize(),
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
                        if (!focused) _applyTargetSize();
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
                        onSubmitted: (_) => _applyTargetSize(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Tooltip(
                    message: '还原为整图',
                    child: IconButton(
                      onPressed: _controller.resetCrop,
                      icon: const Icon(Icons.restart_alt),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                '选区 x ${area.x}, y ${area.y} · ${area.width} × ${area.height}'
                ' · 原图 ${source.width} × ${source.height}'
                '${_lockedRatio != null ? ' · 比例锁定' : ''}',
                style: theme.textTheme.bodySmall,
              ),
              if (state.cropShape == CropShape.circle)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    '圆形选区输出方形画布，圆外填充透明',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.primary,
                    ),
                  ),
                ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: () => context.push(AppRoutes.exportPanel),
                      icon: const Icon(Icons.arrow_forward),
                      label: const Text('下一步：导出'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 比例预设按钮；圆形下非 1:1 置灰（PRD 二.2 合法性矩阵）。
class _AspectChip extends StatelessWidget {
  const _AspectChip({
    required this.aspect,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  final CropAspect aspect;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final chip = ChoiceChip(
      label: Text(aspect.label),
      selected: selected,
      onSelected: enabled ? (_) => onTap() : null,
      visualDensity: VisualDensity.compact,
      labelStyle: const TextStyle(fontSize: 12),
    );
    return enabled ? chip : Tooltip(message: '圆形选区仅支持 1:1', child: chip);
  }
}

/// 手柄在原图区域的落点；圆形只保留四角（不能单独拉边）。
Map<CropHandle, Offset> _handlePositions(Rect rect, CropShape shape) {
  if (shape == CropShape.circle) {
    return {
      CropHandle.topLeft: rect.topLeft,
      CropHandle.topRight: rect.topRight,
      CropHandle.bottomRight: rect.bottomRight,
      CropHandle.bottomLeft: rect.bottomLeft,
    };
  }
  return {
    CropHandle.topLeft: rect.topLeft,
    CropHandle.top: Offset(rect.center.dx, rect.top),
    CropHandle.topRight: rect.topRight,
    CropHandle.right: Offset(rect.right, rect.center.dy),
    CropHandle.bottomRight: rect.bottomRight,
    CropHandle.bottom: Offset(rect.center.dx, rect.bottom),
    CropHandle.bottomLeft: rect.bottomLeft,
    CropHandle.left: Offset(rect.left, rect.center.dy),
  };
}

/// 选区绘制：选区外压暗、边框、8 个手柄。线宽按视图缩放反算以保持视觉恒定。
class _SelectionPainter extends CustomPainter {
  const _SelectionPainter({
    required this.selection,
    required this.shape,
    required this.source,
    required this.fit,
    required this.origin,
    required this.scale,
  });

  final CropSelection selection;
  final CropShape shape;
  final ImageDimensions source;
  final Size fit;
  final Offset origin;
  final double scale;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTWH(
      origin.dx + selection.left * fit.width / source.width,
      origin.dy + selection.top * fit.height / source.height,
      selection.width * fit.width / source.width,
      selection.height * fit.height / source.height,
    );
    final imageRect = Rect.fromLTWH(
      origin.dx,
      origin.dy,
      fit.width,
      fit.height,
    );

    final shapePath = shape == CropShape.circle
        ? (Path()..addOval(rect))
        : (Path()..addRect(rect));
    final outside = Path.combine(
      PathOperation.difference,
      Path()..addRect(imageRect),
      shapePath,
    );
    canvas.drawPath(outside, Paint()..color = const Color(0x73000000));

    final stroke = 1.5 / scale;
    final border = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..color = Colors.white;
    if (shape == CropShape.circle) {
      canvas.drawOval(rect, border);
    } else {
      canvas.drawRect(rect, border);
    }

    // 手柄：实心白圆 + 暗色描边，任何背景下都可见
    final radius = 4.5 / scale;
    final fill = Paint()..color = Colors.white;
    final edge = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1 / scale
      ..color = const Color(0x66000000);
    for (final point in _handlePositions(rect, shape).values) {
      canvas.drawCircle(point, radius, fill);
      canvas.drawCircle(point, radius, edge);
    }
  }

  @override
  bool shouldRepaint(_SelectionPainter old) =>
      old.selection != selection ||
      old.shape != shape ||
      old.source != source ||
      old.fit != fit ||
      old.origin != origin ||
      old.scale != scale;
}

/// 空态：引导选图。
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

/// 「中」态：探测/解码进度（PRD 九.3 三段进度）。
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

/// 失败态：错误码 + 文案 + 重新选择（PRD 九.2）。
class _FailureView extends StatelessWidget {
  const _FailureView({required this.state, required this.onPick});

  final EditorState state;
  final VoidCallback onPick;

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
            FilledButton(
              onPressed: onPick,
              child: Text(isExportError ? '返回' : '重新选择'),
            ),
          ],
        ),
      ),
    );
  }
}
