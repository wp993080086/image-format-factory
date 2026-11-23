import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/image/annotation.dart';
import '../../core/image/image_header_probe.dart';
import '../editor/editor_controller.dart';
import '../editor/editor_state.dart';

/// 标注页（PRD v0.5 / M3）：在图片上叠加七类标注，支持拖动定位与手柄调整。
///
/// 标注存**原图坐标系**（与裁剪一致），视图缩放/平移只影响显示；
/// 导出时由 [EditorController] 映射到裁剪+缩放后的输出坐标再合成。
class AnnotatePage extends ConsumerWidget {
  const AnnotatePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(editorControllerProvider);
    void onPick() => ref.read(editorControllerProvider.notifier).pickAndLoad();
    return Scaffold(
      appBar: AppBar(
        title: const Text('标注'),
        actions: [
          IconButton(
            tooltip: '撤销 (Ctrl+Z)',
            icon: const Icon(Icons.undo),
            onPressed: ref.read(editorControllerProvider.notifier).canUndo
                ? ref.read(editorControllerProvider.notifier).undo
                : null,
          ),
          IconButton(
            tooltip: '重做 (Ctrl+Shift+Z)',
            icon: const Icon(Icons.redo),
            onPressed: ref.read(editorControllerProvider.notifier).canRedo
                ? ref.read(editorControllerProvider.notifier).redo
                : null,
          ),
          IconButton(
            tooltip: '清空标注',
            icon: const Icon(Icons.delete_sweep_outlined),
            onPressed: state.annotations.isEmpty
                ? null
                : () => ref
                      .read(editorControllerProvider.notifier)
                      .clearAnnotations(),
          ),
        ],
      ),
      body: switch (state.stage) {
        EditorStage.empty => _EmptyView(onPick: onPick),
        EditorStage.detecting || EditorStage.decoding => const Center(
          child: CircularProgressIndicator(),
        ),
        EditorStage.editable => _AnnotateEditor(
          key: ValueKey(
            'anno-${state.decoded!.sourceSize.width}x${state.decoded!.sourceSize.height}',
          ),
          state: state,
        ),
        _ => Center(child: Text(state.failure?.message ?? '出错了，请重新选图')),
      },
    );
  }
}

class _EmptyView extends StatelessWidget {
  const _EmptyView({required this.onPick});
  final VoidCallback onPick;

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.draw, size: 64, color: Colors.grey),
        const SizedBox(height: 16),
        const Text('先选一张图片开始标注'),
        const SizedBox(height: 16),
        FilledButton(onPressed: onPick, child: const Text('选择图片')),
      ],
    ),
  );
}

/// 工具类型：select 为选择/调整，其余为新建标注。
enum _Tool {
  select(Icons.near_me, '选择'),
  text(Icons.text_fields, '文字'),
  line(Icons.remove, '直线'),
  arrow(Icons.north_east, '箭头'),
  rectangle(Icons.crop_square, '矩形'),
  circle(Icons.circle_outlined, '圆形'),
  ellipse(Icons.circle, '椭圆'),
  mosaic(Icons.grid_on, '马赛克'),
  brush(Icons.blur_on, '涂抹打码'),
  // v0.7 点按放码：两个预设马赛克块，单击即放（纯手动，不做任何识别）。
  avatarBlock(Icons.account_circle, '头像块'),
  nicknameBar(Icons.subject, '昵称条');

  const _Tool(this.icon, this.label);
  final IconData icon;
  final String label;

  AnnotationType? get annotationType => switch (this) {
    _Tool.text => AnnotationType.text,
    _Tool.line => AnnotationType.line,
    _Tool.arrow => AnnotationType.arrow,
    _Tool.rectangle => AnnotationType.rectangle,
    _Tool.circle => AnnotationType.circle,
    _Tool.ellipse => AnnotationType.ellipse,
    _Tool.mosaic => AnnotationType.mosaic,
    _Tool.brush => AnnotationType.brush,
    // 点按放码落到普通马赛克标注，完全复用选中/手柄/撤销/导出/批量管线
    _Tool.avatarBlock => AnnotationType.mosaic,
    _Tool.nicknameBar => AnnotationType.mosaic,
    _Tool.select => null,
  };

  /// 点按放码的默认块尺寸（**屏幕逻辑像素**，非原图像素）。
  /// 落块时按当前视图缩放反算成原图坐标，保证屏幕上看到的始终是这么大——
  /// 高分辨率图片缩到屏幕后，若按原图像素放块会小到只剩几个像素（真机反馈）。
  Size? get tapPresetSize => switch (this) {
    _Tool.avatarBlock => const Size(48, 48),
    _Tool.nicknameBar => const Size(70, 28),
    _ => null,
  };
}

/// 拖拽模式。
enum _Mode { none, view, move, handle, create }

/// 文字输入对话框的返回值。
/// 字号不在这里选：放置后由四角手柄等比缩放（拖角同时改字号，避免两套尺寸）。
class _TextInput {
  const _TextInput(this.text, this.colorArgb);
  final String text;
  final int colorArgb;
}

/// 视图适配模式（长图关键：contain 会把长图缩成一条，改按宽度铺满后可上下拖动）。
enum _FitMode {
  contain(Icons.aspect_ratio, '适应'),
  width(Icons.height, '宽');

  const _FitMode(this.icon, this.label);
  final IconData icon;
  final String label;
}

/// 手柄方位（框类 4 角 + 线类 2 端）。
enum _Handle { tl, tr, bl, br, start, end }

class _AnnotateEditor extends ConsumerStatefulWidget {
  const _AnnotateEditor({super.key, required this.state});

  final EditorState state;

  @override
  ConsumerState<_AnnotateEditor> createState() => _AnnotateEditorState();
}

class _AnnotateEditorState extends ConsumerState<_AnnotateEditor> {
  static const _maxScale = 8.0;
  static const _handleHitRadius = 18.0;

  _Tool _tool = _Tool.select;
  _Mode _mode = _Mode.none;
  _Handle? _handle;

  double _scale = 1;
  Offset _offset = Offset.zero;
  Offset _startLocal = Offset.zero;
  Offset? _zoomAnchor;
  double _startScale = 1;
  Offset _startOffset = Offset.zero;

  /// 视图适配：长图（高/宽 ≥ 1.5）默认按宽度铺满，否则整体适应。
  /// 切换会重置缩放与平移，避免旧视图参数把新图拖到视口外。
  late _FitMode _fitMode;

  @override
  void initState() {
    super.initState();
    final s = widget.state.decoded!.sourceSize;
    _fitMode = s.height >= s.width * 1.5 ? _FitMode.width : _FitMode.contain;
  }

  void _setFitMode(_FitMode mode) => setState(() {
    _fitMode = mode;
    _scale = 1;
    _offset = Offset.zero;
  });

  /// 拖拽期间的原图坐标快照。
  Offset _startOrigin = Offset.zero;
  Annotation? _startAnnotation;
  int? _draftIndex;

  /// 新建标注草稿（原图坐标）。
  Annotation? _draft;

  final _canvasFocus = FocusNode(debugLabel: 'annotateCanvas');

  EditorController get _controller =>
      ref.read(editorControllerProvider.notifier);

  ImageDimensions get _source => widget.state.decoded!.sourceSize;
  List<Annotation> get _annotations => widget.state.annotations;
  int? get _selected => widget.state.selectedAnnotation;

  @override
  void dispose() {
    _canvasFocus.dispose();
    super.dispose();
  }

  // ---------- 坐标换算（复用 crop_page 模式） ----------

  Matrix4 _viewMatrix(Size box) {
    final c = Offset(box.width / 2, box.height / 2);
    return Matrix4.translationValues(_offset.dx, _offset.dy, 0)
      ..multiply(Matrix4.translationValues(c.dx, c.dy, 0))
      ..multiply(Matrix4.diagonal3Values(_scale, _scale, 1))
      ..multiply(Matrix4.translationValues(-c.dx, -c.dy, 0));
  }

  Offset _toCanvas(Offset local, Size box) =>
      MatrixUtils.transformPoint(Matrix4.inverted(_viewMatrix(box)), local);

  /// 适应模式下的图片显示尺寸。
  /// - contain：整图塞进视口（普通图默认，长图会缩成细条）。
  /// - width：按视口宽度铺满，高度按比例放大后可超出视口，上下拖动查看（长图默认）。
  Size _fitSize(Size box) {
    final ia = _source.width / _source.height;
    final ba = box.width / box.height;
    if (_fitMode == _FitMode.width) {
      return Size(box.width, box.width / ia);
    }
    return ia > ba
        ? Size(box.width, box.width / ia)
        : Size(box.height * ia, box.height);
  }

  /// 图片左上角在画布坐标系的位置。
  /// 宽度模式下图比视口高，顶边对齐（dy=0）而非居中，保证从顶部开始看长图。
  Offset _origin(Size box) {
    final fit = _fitSize(box);
    final dx = (box.width - fit.width) / 2;
    final dy = fit.height > box.height ? 0.0 : (box.height - fit.height) / 2;
    return Offset(dx, dy);
  }

  Offset _toOrigin(Offset local, Size box) {
    final canvas = _toCanvas(local, box);
    final fit = _fitSize(box);
    final org = _origin(box);
    return Offset(
      (canvas.dx - org.dx) * _source.width / fit.width,
      (canvas.dy - org.dy) * _source.height / fit.height,
    );
  }

  Rect _originRect(Annotation a) {
    if (a.type == AnnotationType.brush && a.points.length >= 2) {
      var minX = a.points[0], maxX = a.points[0];
      var minY = a.points[1], maxY = a.points[1];
      for (var i = 2; i < a.points.length; i += 2) {
        minX = math.min(minX, a.points[i]);
        maxX = math.max(maxX, a.points[i]);
        minY = math.min(minY, a.points[i + 1]);
        maxY = math.max(maxY, a.points[i + 1]);
      }
      final r = a.brushRadius;
      return Rect.fromLTRB(
        (minX - r).toDouble(),
        (minY - r).toDouble(),
        (maxX + r).toDouble(),
        (maxY + r).toDouble(),
      );
    }
    return Rect.fromLTRB(
      math.min(a.x1, a.x2).toDouble(),
      math.min(a.y1, a.y2).toDouble(),
      math.max(a.x1, a.x2).toDouble(),
      math.max(a.y1, a.y2).toDouble(),
    );
  }

  Rect _screenRect(Annotation a, Size box) {
    final fit = _fitSize(box);
    final org = _origin(box);
    final r = _originRect(a);
    final sx = fit.width / _source.width;
    final sy = fit.height / _source.height;
    return Rect.fromLTWH(
      org.dx + r.left * sx,
      org.dy + r.top * sy,
      r.width * sx,
      r.height * sy,
    );
  }

  Offset _screenPoint(double x, double y, Size box) {
    final fit = _fitSize(box);
    final org = _origin(box);
    return Offset(
      org.dx + x * fit.width / _source.width,
      org.dy + y * fit.height / _source.height,
    );
  }

  List<({_Handle key, Offset pos})> _handles(Annotation a) {
    final r = _originRect(a);
    if (a.type == AnnotationType.line || a.type == AnnotationType.arrow) {
      return [
        (key: _Handle.start, pos: Offset(a.x1.toDouble(), a.y1.toDouble())),
        (key: _Handle.end, pos: Offset(a.x2.toDouble(), a.y2.toDouble())),
      ];
    }
    // 涂抹逐点编辑超出当前交互范围，不给手柄；
    // 文字保留四角手柄，拖角时整体等比缩放（见 _resizeText）。
    if (a.type == AnnotationType.brush) {
      return const [];
    }
    return [
      (key: _Handle.tl, pos: Offset(r.left, r.top)),
      (key: _Handle.tr, pos: Offset(r.right, r.top)),
      (key: _Handle.bl, pos: Offset(r.left, r.bottom)),
      (key: _Handle.br, pos: Offset(r.right, r.bottom)),
    ];
  }

  // ---------- 命中测试 ----------

  ({_Mode mode, _Handle? handle, int? index}) _hitTest(Offset local, Size box) {
    final canvas = _toCanvas(local, box);
    final threshold = _handleHitRadius / _scale;
    final selected = _selected;

    // 先测选中项的手柄
    if (selected != null && selected < _annotations.length) {
      final a = _annotations[selected];
      for (final h in _handles(a)) {
        final hp = _screenPoint(h.pos.dx, h.pos.dy, box);
        if ((canvas - hp).distance <= threshold) {
          return (mode: _Mode.handle, handle: h.key, index: selected);
        }
      }
    }
    // 再测选中项本体（移动）
    if (selected != null && selected < _annotations.length) {
      final r = _screenRect(_annotations[selected], box);
      if (r.inflate(4 / _scale).contains(canvas)) {
        return (mode: _Mode.move, handle: null, index: selected);
      }
    }
    // 最后从后往前找可点中的标注
    for (var i = _annotations.length - 1; i >= 0; i--) {
      final r = _screenRect(_annotations[i], box);
      if (r.inflate(4 / _scale).contains(canvas)) {
        return (mode: _Mode.move, handle: null, index: i);
      }
    }
    return (mode: _Mode.view, handle: null, index: null);
  }

  // ---------- 手势 ----------

  void _onScaleStart(ScaleStartDetails d, Size box) {
    if (!_canvasFocus.hasFocus) _canvasFocus.requestFocus();
    _startScale = _scale;
    _startOffset = _offset;
    _startLocal = d.localFocalPoint;
    if (d.pointerCount >= 2) {
      _mode = _Mode.view;
      _zoomAnchor = _toCanvas(d.localFocalPoint, box);
      return;
    }
    _zoomAnchor = null;
    _startOrigin = _toOrigin(d.localFocalPoint, box);

    // 空格 + 拖动 = 强制平移视图（长图查看时不误触绘制工具）。
    // 与 select 工具拖空白处一致，但任何工具下都生效。
    if (HardwareKeyboard.instance.logicalKeysPressed.contains(
      LogicalKeyboardKey.space,
    )) {
      _mode = _Mode.view;
      return;
    }

    // 命中优先：点到已有标注的手柄或本体就进入调整，只有点空白处才新建。
    // 这样文字点本体不再重复弹窗、线/形状手柄生效、头像块落块后可直接拖动，
    // 且头像块无需切回"选择"工具也能连续放置（真机反馈的三个问题同源）。
    final hit = _hitTest(d.localFocalPoint, box);
    if (hit.mode == _Mode.move || hit.mode == _Mode.handle) {
      _mode = hit.mode;
      _handle = hit.handle;
      _controller.selectAnnotation(hit.index);
      // 一次拖动 = 一次撤销：手势期间不逐帧压历史
      _controller.beginAnnotationGesture();
      _startAnnotation = _annotations[hit.index!];
      _draftIndex = hit.index;
      return;
    }

    // 点在空白处：取消选中，按当前工具决定是否新建。
    _controller.selectAnnotation(null);
    final type = _tool.annotationType;
    if (type != null) {
      // 文字工具：落点弹输入框，确认后才创建（避免"点一下凭空出现文字"却无从编辑）。
      if (type == AnnotationType.text) {
        _mode = _Mode.none;
        _startTextAt(_startOrigin);
        return;
      }
      // 绘制工具：在落点新建标注草稿
      _mode = _Mode.create;
      final preset = _tool.tapPresetSize;
      late final int x1, y1, x2, y2;
      if (preset == null) {
        x1 = x2 = _startOrigin.dx.round();
        y1 = y2 = _startOrigin.dy.round();
      } else {
        // 点按放码：预设是屏幕逻辑像素，需按当前视图缩放反算成原图尺寸，
        // 这样不管图片分辨率多高、视图缩放到多少，屏幕上看到的块都固定大小。
        // sx/sy 与 _screenPoint 的换算一致（含用户缩放 _scale）。
        final fit = _fitSize(box);
        final sx = fit.width * _scale / _source.width;
        final sy = fit.height * _scale / _source.height;
        final w = (preset.width / sx).round().clamp(1, _source.width);
        final h = (preset.height / sy).round().clamp(1, _source.height);
        x1 = (_startOrigin.dx - w / 2)
            .round()
            .clamp(0, _source.width - w)
            .toInt();
        y1 = (_startOrigin.dy - h / 2)
            .round()
            .clamp(0, _source.height - h)
            .toInt();
        x2 = x1 + w;
        y2 = y1 + h;
      }
      _draft = Annotation(
        type: type,
        x1: x1,
        y1: y1,
        x2: x2,
        y2: y2,
        colorArgb: 0xFFFF0000,
        strokeWidth: 3,
        text: type == AnnotationType.text ? '文字' : '',
        fontSize: 24,
        mosaicBlock: 12,
        // 涂抹打码：起点作为轨迹第一个点，半径/模式在属性条可调
        points: type == AnnotationType.brush
            ? [_startOrigin.dx.round(), _startOrigin.dy.round()]
            : const [],
        brushMode: BrushMode.mosaic,
        brushRadius: 24,
      );
      setState(() {});
      return;
    }

    // 选择工具点空白：平移视图
    _mode = _Mode.view;
  }

  /// 文字标注：在落点弹出输入框，确认后以该点为左上角创建标注。
  /// 颜色在这里一次设定；字号固定，放置后用四角手柄等比缩放。
  Future<void> _startTextAt(Offset origin) async {
    final controller = TextEditingController();
    var colorArgb = 0xFFFF0000;
    final result = await showDialog<_TextInput>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('添加文字标注'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: controller,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: '文字内容',
                    border: OutlineInputBorder(),
                  ),
                  textInputAction: TextInputAction.done,
                  onSubmitted: (v) => Navigator.pop(
                    dialogContext,
                    _TextInput(v.trim(), colorArgb),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    const Text('颜色'),
                    const SizedBox(width: 12),
                    for (final argb in [
                      0xFFFF0000,
                      0xFF00C853,
                      0xFF2962FF,
                      0xFFFFFFFF,
                      0xFF000000,
                    ])
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: GestureDetector(
                          onTap: () => setDialogState(() => colorArgb = argb),
                          child: Container(
                            width: 28,
                            height: 28,
                            decoration: BoxDecoration(
                              color: Color(argb),
                              shape: BoxShape.circle,
                              border: colorArgb == argb
                                  ? Border.all(color: Colors.grey, width: 3)
                                  : null,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(
                dialogContext,
                _TextInput(controller.text.trim(), colorArgb),
              ),
              child: const Text('添加'),
            ),
          ],
        ),
      ),
    );
    // controller 交给对话框持有，_dialog 关闭后再由 Flutter 回收；
    // 这里不能提前 dispose——退出动画期间 TextField 仍会引用它。
    if (result == null || result.text.isEmpty || !mounted) return;
    // 框按绘制端同一套 TextPainter 度量生成，四角手柄才能贴着文字；
    // 不加额外 padding——否则框右下多出一圈，看起来"文字偏上、框偏大"。
    // 框存原图坐标（除以 sx/sy），视图缩放只影响显示。
    const fontSize = 24;
    final fit = _fitSize(MediaQuery.sizeOf(context));
    final sx = fit.width / _source.width;
    final sy = fit.height / _source.height;
    final tp = TextPainter(
      text: TextSpan(
        text: result.text,
        style: TextStyle(
          fontSize: fontSize * _scale,
          fontFamily: 'Noto Sans SC',
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    // 用字号作为尺寸下限：TextPainter 的 height 是行高，在部分环境（尤其
    // 中文字体缺失 fallback 时）会远小于字形实际高度，导致框过扁、手柄重叠、
    // 文字看起来"偏上"。下限保证框至少能包住一个字。
    final w = math.max(tp.width / sx, fontSize.toDouble());
    final h = math.max(tp.height / sy, fontSize.toDouble());
    _controller.addAnnotation(
      Annotation(
        type: AnnotationType.text,
        x1: origin.dx.round().clamp(0, _source.width),
        y1: origin.dy.round().clamp(0, _source.height),
        x2: (origin.dx + w).round().clamp(0, _source.width),
        y2: (origin.dy + h).round().clamp(0, _source.height),
        colorArgb: result.colorArgb,
        strokeWidth: 3,
        text: result.text,
        fontSize: fontSize,
      ),
    );
  }

  void _onScaleUpdate(ScaleUpdateDetails d, Size box) {
    if (d.pointerCount >= 2 && _zoomAnchor != null) {
      _applyZoom(d, box);
      return;
    }
    final now = _toOrigin(d.localFocalPoint, box);
    switch (_mode) {
      case _Mode.create:
        final base = _draft;
        if (base == null) return;
        // 点按放码：落块尺寸固定，拖动不拉伸（点一下即放好，之后拖手柄调整）
        if (_tool.tapPresetSize != null) return;
        var x2 = now.dx.round();
        var y2 = now.dy.round();
        if (base.type == AnnotationType.brush) {
          // 涂抹：连续采样轨迹点，间距至少 2px（原图坐标）以控制点数。
          // x1/y1/x2/y2 同步跟随末点，供命中测试/选中框使用。
          final pts = List<int>.from(base.points);
          final lastX = pts[pts.length - 2];
          final lastY = pts[pts.length - 1];
          if ((x2 - lastX).abs() >= 2 || (y2 - lastY).abs() >= 2) {
            pts
              ..add(x2)
              ..add(y2);
            setState(() {
              _draft = base.copyWith(points: pts, x2: x2, y2: y2);
            });
          }
          return;
        }
        if (_tool == _Tool.circle) {
          // 圆形强制正方形：取较长边
          final side = math.max((x2 - base.x1).abs(), (y2 - base.y1).abs());
          x2 = base.x1 + (x2 >= base.x1 ? side : -side);
          y2 = base.y1 + (y2 >= base.y1 ? side : -side);
        }
        setState(() {
          _draft = base.copyWith(x2: x2, y2: y2);
        });
      case _Mode.move:
        final base = _startAnnotation;
        final idx = _draftIndex;
        if (base == null || idx == null) return;
        final dx = (now.dx - _startOrigin.dx).round();
        final dy = (now.dy - _startOrigin.dy).round();
        final shifted =
            base.type == AnnotationType.brush && base.points.length >= 2
            ? [
                for (var i = 0; i < base.points.length; i += 2) ...[
                  base.points[i] + dx,
                  base.points[i + 1] + dy,
                ],
              ]
            : null;
        _controller.updateAnnotation(
          idx,
          base.copyWith(
            x1: base.x1 + dx,
            y1: base.y1 + dy,
            x2: base.x2 + dx,
            y2: base.y2 + dy,
            points: shifted ?? base.points,
          ),
        );
      case _Mode.handle:
        final base = _startAnnotation;
        final idx = _draftIndex;
        final h = _handle;
        if (base == null || idx == null || h == null) return;
        _controller.updateAnnotation(idx, _resize(base, h, now));
      case _Mode.view:
        if (_zoomAnchor != null) {
          _applyZoom(d, box);
        } else {
          setState(() {
            _offset = _clampOffset(
              _startOffset + (d.localFocalPoint - _startLocal),
              box,
            );
          });
        }
      case _Mode.none:
        break;
    }
  }

  /// 文字等比缩放：拖任一角，对角保持不动，字号与框按同一比例变化。
  /// 只提供"整体放大/缩小"，不单独拉伸宽高，因此宽高比始终不变。
  Annotation _resizeText(Annotation base, _Handle h, Offset now) {
    final r = _originRect(base);
    if (r.width < 1 || r.height < 1) return base;
    final isLeft = h == _Handle.tl || h == _Handle.bl;
    final isTop = h == _Handle.tl || h == _Handle.tr;
    // 锚点是对角；拖动点与锚点的距离 / 原手柄与锚点的距离 = 缩放比例。
    final anchor = Offset(isLeft ? r.right : r.left, isTop ? r.bottom : r.top);
    final diagonal = math.sqrt(r.width * r.width + r.height * r.height);
    final factor = (now - anchor).distance / diagonal;
    final fontSize = (base.fontSize * factor).round().clamp(6, 200);
    final k = fontSize / base.fontSize;
    final w = r.width * k;
    final h2 = r.height * k;
    return base.copyWith(
      x1: (isLeft ? anchor.dx - w : anchor.dx).round(),
      y1: (isTop ? anchor.dy - h2 : anchor.dy).round(),
      x2: (isLeft ? anchor.dx : anchor.dx + w).round(),
      y2: (isTop ? anchor.dy : anchor.dy + h2).round(),
      fontSize: fontSize,
    );
  }

  Annotation _resize(Annotation base, _Handle h, Offset now) {
    if (base.type == AnnotationType.text) return _resizeText(base, h, now);
    final x = now.dx.round();
    final y = now.dy.round();
    switch (h) {
      case _Handle.start:
        return base.copyWith(x1: x, y1: y);
      case _Handle.end:
        return base.copyWith(x2: x, y2: y);
      case _Handle.tl:
        return base.copyWith(x1: x, y1: y);
      case _Handle.tr:
        return base.copyWith(x2: x, y1: y);
      case _Handle.bl:
        return base.copyWith(x1: x, y2: y);
      case _Handle.br:
        return base.copyWith(x2: x, y2: y);
    }
  }

  void _onScaleEnd(ScaleEndDetails d) {
    // 新建标注：落笔即提交一次（撤销粒度 = 一次绘制）
    final placedPreset = _mode == _Mode.create && _tool.tapPresetSize != null;
    if (_mode == _Mode.create && _draft != null) {
      final draft = _draft!;
      if (draft.type == AnnotationType.brush) {
        // 涂抹：一个点也有效（单击涂抹出一个圆点），轨迹至少 2 个数（1 个点）
        if (draft.points.length >= 2) {
          _controller.addAnnotation(draft);
        }
      } else {
        final r = _originRect(draft);
        // 预设块已有固定尺寸，不参与"太小视为误触"判定。
        if (placedPreset || r.width >= 3 || r.height >= 3) {
          _controller.addAnnotation(draft);
        } else if (draft.type == AnnotationType.text) {
          _controller.addAnnotation(
            draft.copyWith(x2: draft.x1 + 120, y2: draft.y1 + 30),
          );
        }
      }
    }
    _controller.endAnnotationGesture();
    _mode = _Mode.none;
    _handle = null;
    _startAnnotation = null;
    _draftIndex = null;
    _draft = null;
    _zoomAnchor = null;
    setState(() {});
  }

  void _applyZoom(ScaleUpdateDetails d, Size box) {
    final anchor = _zoomAnchor;
    if (anchor == null) return;
    final newScale = (_startScale * d.scale).clamp(1.0, _maxScale);
    final c = Offset(box.width / 2, box.height / 2);
    final local = d.localFocalPoint;
    setState(() {
      _scale = newScale;
      _offset = _clampOffset(
        Offset(
          local.dx - c.dx - (anchor.dx - c.dx) * newScale,
          local.dy - c.dy - (anchor.dy - c.dy) * newScale,
        ),
        box,
      );
    });
  }

  /// 滚轮缩放（桌面端长图查看），以指针位置为锚点，逻辑与裁剪页一致。
  void _onPointerSignal(PointerSignalEvent event, Size box) {
    if (event is! PointerScrollEvent) return;
    final factor = event.scrollDelta.dy > 0 ? 0.9 : 1.1;
    final newScale = (_scale * factor).clamp(1.0, _maxScale);
    if (newScale == _scale) return;
    final anchor = _toCanvas(event.localPosition, box);
    final c = Offset(box.width / 2, box.height / 2);
    final local = event.localPosition;
    setState(() {
      _scale = newScale;
      _offset = _clampOffset(
        Offset(
          local.dx - c.dx - (anchor.dx - c.dx) * newScale,
          local.dy - c.dy - (anchor.dy - c.dy) * newScale,
        ),
        box,
      );
    });
  }

  /// 限制平移，保证图至少有一部分留在视口内，长图上下拖也不会把图整个拖丢。
  Offset _clampOffset(Offset value, Size box) {
    const keep = 48.0;
    final c = Offset(box.width / 2, box.height / 2);
    final fit = _fitSize(box);
    final org = _origin(box);
    final left0 = c.dx + (org.dx - c.dx) * _scale;
    final right0 = c.dx + (org.dx + fit.width - c.dx) * _scale;
    final top0 = c.dy + (org.dy - c.dy) * _scale;
    final bottom0 = c.dy + (org.dy + fit.height - c.dy) * _scale;
    double axis(double v, double lo, double hi) =>
        lo > hi ? (lo + hi) / 2 : v.clamp(lo, hi);
    return Offset(
      axis(value.dx, keep - right0, box.width - keep - left0),
      axis(value.dy, keep - bottom0, box.height - keep - top0),
    );
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final ctrl =
        HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isMetaPressed;
    if (ctrl && event.logicalKey == LogicalKeyboardKey.keyZ) {
      final shift = HardwareKeyboard.instance.isShiftPressed;
      if (shift) {
        if (_controller.canRedo) _controller.redo();
      } else if (_controller.canUndo) {
        _controller.undo();
      }
      return KeyEventResult.handled;
    }
    // Delete 删除选中标注
    if ((event.logicalKey == LogicalKeyboardKey.delete ||
            event.logicalKey == LogicalKeyboardKey.backspace) &&
        _selected != null) {
      _controller.removeAnnotation(_selected!);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _buildToolbar(),
        _buildViewBar(),
        _buildBlurBar(),
        Expanded(child: _buildCanvas()),
        // 属性条避开系统底部手势区，避免手机上"太靠下"够不着
        const SafeArea(
          top: false,
          left: false,
          right: false,
          child: _PropertyBar(),
        ),
      ],
    );
  }

  /// 视图适配条：长图在「宽」模式下按视口宽度铺满、可上下拖动；
  /// 「适应」模式把整图塞进视口。切换即重置缩放/平移。
  Widget _buildViewBar() {
    return Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        border: Border(
          bottom: BorderSide(color: Theme.of(context).dividerColor),
        ),
      ),
      child: Row(
        children: [
          const Text('视图', style: TextStyle(fontSize: 13)),
          const SizedBox(width: 8),
          SegmentedButton<_FitMode>(
            segments: [
              for (final m in _FitMode.values)
                ButtonSegment(
                  value: m,
                  label: Text(m.label),
                  icon: Icon(m.icon),
                ),
            ],
            selected: {_fitMode},
            onSelectionChanged: (v) => _setFitMode(v.first),
            showSelectedIcon: false,
            style: const ButtonStyle(visualDensity: VisualDensity.compact),
          ),
          const Spacer(),
          Text(
            _fitMode == _FitMode.width ? '上下拖动查看' : '双指/滚轮缩放',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  /// 整图模糊（毛玻璃）控制条：滑块实时改强度，画布用 ImageFiltered 预览。
  /// 0 表示关闭；导出时按同一强度做真实高斯模糊（见 blur.dart）。
  Widget _buildBlurBar() {
    final blur = widget.state.blur;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLowest,
        border: Border(
          bottom: BorderSide(color: Theme.of(context).dividerColor),
        ),
      ),
      child: Row(
        children: [
          const Icon(Icons.blur_on, size: 18),
          const SizedBox(width: 8),
          const Text('整图模糊'),
          const Spacer(),
          SizedBox(
            width: 200,
            child: Slider(
              value: blur.toDouble(),
              min: 0,
              max: 100,
              divisions: 20,
              label: blur == 0 ? '关' : '$blur',
              onChanged: (v) => _controller.setBlur(v.round()),
            ),
          ),
          SizedBox(
            width: 40,
            child: Text(blur == 0 ? '关' : '$blur', textAlign: TextAlign.end),
          ),
        ],
      ),
    );
  }

  /// 底图预览：blur=0 直接显示原预览，>0 时套 ImageFiltered 做毛玻璃。
  ///
  /// sigma 按预览尺度近似（导出按全图短边算半径，见 blur.dart），只求观感一致。
  Widget _blurredPreview(int blur) {
    final image = Image.memory(
      widget.state.decoded!.previewPng,
      fit: BoxFit.fill,
      filterQuality: FilterQuality.medium,
      gaplessPlayback: true,
    );
    if (blur <= 0) return image;
    final sigma = (blur / 100 * 14).clamp(0.5, 14.0);
    return ImageFiltered(
      imageFilter: ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
      child: image,
    );
  }

  Widget _buildToolbar() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(
        children: [
          for (final tool in _Tool.values)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: ChoiceChip(
                label: Text(tool.label),
                avatar: Icon(tool.icon, size: 16),
                selected: _tool == tool,
                onSelected: (_) => setState(() => _tool = tool),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildCanvas() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final box = Size(constraints.maxWidth, constraints.maxHeight);
        if (box.isEmpty) return const SizedBox.shrink();
        return Focus(
          key: const ValueKey('annotateCanvas'),
          focusNode: _canvasFocus,
          autofocus: true,
          onKeyEvent: _onKey,
          child: Semantics(
            container: true,
            label: '标注画布',
            value: '${_annotations.length} 条标注，当前工具 ${_tool.label}',
            hint: '双指或滚轮缩放，按住空格拖动平移视图',
            child: Listener(
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
                              left: _origin(box).dx,
                              top: _origin(box).dy,
                              width: _fitSize(box).width,
                              height: _fitSize(box).height,
                              // 整图模糊实时预览：仅糊底图，标注层在其上保持清晰，
                              // 与导出时「先模糊后叠标注」的顺序一致。
                              child: _blurredPreview(widget.state.blur),
                            ),
                            Positioned.fill(
                              child: IgnorePointer(
                                child: CustomPaint(
                                  painter: _AnnotationPainter(
                                    annotations: _annotations,
                                    draft: _draft,
                                    selected: _selected,
                                    source: _source,
                                    fit: _fitSize(box),
                                    origin: _origin(box),
                                    scale: _scale,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 属性条：编辑选中标注的颜色/线宽/马赛克块/涂抹方式。
class _PropertyBar extends ConsumerWidget {
  const _PropertyBar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(editorControllerProvider);
    final idx = state.selectedAnnotation;
    if (idx == null || idx >= state.annotations.length) {
      return const SizedBox(height: 48);
    }
    final a = state.annotations[idx];
    final c = ref.read(editorControllerProvider.notifier);
    final color = Color(a.colorArgb);

    return Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        border: Border(top: BorderSide(color: Theme.of(context).dividerColor)),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 文字、线、箭头、形状都要能改颜色；马赛克/涂抹的颜色是占位色，不给改
            if (a.type != AnnotationType.mosaic &&
                a.type != AnnotationType.brush)
              IconButton(
                tooltip: '颜色',
                icon: Icon(Icons.palette, color: color),
                onPressed: () => _pickColor(context, ref, a, idx),
              ),
            if (a.type != AnnotationType.text &&
                a.type != AnnotationType.mosaic &&
                a.type != AnnotationType.brush)
              SizedBox(
                width: 170,
                child: Row(
                  children: [
                    const Text('线宽'),
                    Expanded(
                      child: Slider(
                        value: a.strokeWidth.toDouble().clamp(1, 20),
                        min: 1,
                        max: 20,
                        onChangeStart: (_) => c.beginAnnotationGesture(),
                        onChangeEnd: (_) => c.endAnnotationGesture(),
                        onChanged: (v) => c.updateAnnotation(
                          idx,
                          a.copyWith(strokeWidth: v.round()),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            // 文案在放置弹窗里输入，字号由画布四角手柄等比缩放，
            // 属性条不再提供字号滑块（避免与手柄缩放两套尺寸互相打架）。
            if (a.type == AnnotationType.mosaic)
              SizedBox(
                width: 170,
                child: Row(
                  children: [
                    const Text('块'),
                    Expanded(
                      child: Slider(
                        value: a.mosaicBlock.toDouble().clamp(2, 40),
                        min: 2,
                        max: 40,
                        onChangeStart: (_) => c.beginAnnotationGesture(),
                        onChangeEnd: (_) => c.endAnnotationGesture(),
                        onChanged: (v) => c.updateAnnotation(
                          idx,
                          a.copyWith(mosaicBlock: v.round()),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            if (a.type == AnnotationType.brush) ...[
              SegmentedButton<BrushMode>(
                segments: const [
                  ButtonSegment(value: BrushMode.mosaic, label: Text('马赛克')),
                  ButtonSegment(value: BrushMode.blur, label: Text('模糊')),
                ],
                selected: {a.brushMode},
                onSelectionChanged: (v) =>
                    c.updateAnnotation(idx, a.copyWith(brushMode: v.first)),
                showSelectedIcon: false,
                style: const ButtonStyle(visualDensity: VisualDensity.compact),
              ),
              SizedBox(
                width: 160,
                child: Row(
                  children: [
                    const Text('笔刷'),
                    Expanded(
                      child: Slider(
                        value: a.brushRadius.toDouble().clamp(4, 60),
                        min: 4,
                        max: 60,
                        onChangeStart: (_) => c.beginAnnotationGesture(),
                        onChangeEnd: (_) => c.endAnnotationGesture(),
                        onChanged: (v) => c.updateAnnotation(
                          idx,
                          a.copyWith(brushRadius: v.round()),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _pickColor(
    BuildContext context,
    WidgetRef ref,
    Annotation a,
    int idx,
  ) async {
    final picked = await showDialog<int>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('标注颜色'),
        children: [
          for (final argb in [
            0xFFFF0000,
            0xFF00C853,
            0xFF2962FF,
            0xFFFFC400,
            0xFFFFFFFF,
            0xFF000000,
          ])
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, argb),
              child: Row(
                children: [
                  Container(
                    width: 20,
                    height: 20,
                    color: Color(argb),
                    margin: const EdgeInsets.only(right: 12),
                  ),
                  Text(argb.toRadixString(16)),
                ],
              ),
            ),
        ],
      ),
    );
    if (picked != null && context.mounted) {
      ref
          .read(editorControllerProvider.notifier)
          .updateAnnotation(idx, a.copyWith(colorArgb: picked));
    }
  }
}

/// 画布绘制：七类标注 + 选中手柄。
class _AnnotationPainter extends CustomPainter {
  const _AnnotationPainter({
    required this.annotations,
    required this.draft,
    required this.selected,
    required this.source,
    required this.fit,
    required this.origin,
    required this.scale,
  });

  final List<Annotation> annotations;
  final Annotation? draft;
  final int? selected;
  final ImageDimensions source;
  final Size fit;
  final Offset origin;
  final double scale;

  Offset _p(double x, double y) => Offset(
    origin.dx + x * fit.width / source.width,
    origin.dy + y * fit.height / source.height,
  );

  @override
  void paint(Canvas canvas, Size size) {
    final all = draft == null ? annotations : [...annotations, draft!];
    for (var i = 0; i < all.length; i++) {
      final a = all[i];
      final isSelected = i == selected && draft == null;
      _drawOne(canvas, a, isSelected, draft != null && i == all.length - 1);
    }
  }

  void _drawOne(Canvas canvas, Annotation a, bool isSelected, bool isDraft) {
    final color = Color(a.colorArgb);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = a.strokeWidth * scale * (fit.width / source.width) + 0.5;
    final p1 = _p(a.x1.toDouble(), a.y1.toDouble());
    final p2 = _p(a.x2.toDouble(), a.y2.toDouble());
    final rect = Rect.fromPoints(p1, p2);

    switch (a.type) {
      case AnnotationType.text:
        final tp = TextPainter(
          text: TextSpan(
            text: a.text,
            style: TextStyle(
              color: color,
              fontSize: a.fontSize * scale,
              fontFamily: 'Noto Sans SC',
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvas, p1);
        // 选中文字：虚框与四角手柄共用 x1/y1~x2/y2，拖本体定位、拖角等比缩放。
        if (isSelected) {
          canvas.drawRect(
            rect.inflate(2),
            Paint()
              ..color = Colors.white.withValues(alpha: 0.9)
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1,
          );
        }
        break;
      case AnnotationType.line:
        canvas.drawLine(p1, p2, paint);
        break;
      case AnnotationType.arrow:
        _drawArrow(canvas, p1, p2, paint);
        break;
      case AnnotationType.rectangle:
        canvas.drawRect(rect, paint);
        break;
      case AnnotationType.circle:
        final r = math.min(rect.width, rect.height) / 2;
        canvas.drawCircle(rect.center, r, paint);
        break;
      case AnnotationType.ellipse:
        canvas.drawOval(rect, paint);
        break;
      case AnnotationType.mosaic:
        // 固定雪花点：预览直接用与导出相同的 snowGray 画块，零像素计算。
        _drawSnowRect(canvas, a.x1, a.y1, a.x2, a.y2, a.mosaicBlock);
        if (isSelected) canvas.drawRect(rect, paint..strokeWidth = 1.5);
        break;
      case AnnotationType.brush:
        // 马赛克涂抹画雪花轨迹；毛玻璃（blur）用半透明示意（无法用雪花表达）。
        if (a.brushMode == BrushMode.blur) {
          _drawBrushPreview(canvas, a);
        } else {
          _drawSnowStroke(canvas, a);
        }
        break;
    }

    if (isSelected && a.type != AnnotationType.brush) {
      final hp = Paint()
        ..color = Colors.white
        ..style = PaintingStyle.fill;
      final outline = Paint()
        ..color = Colors.black
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1;
      final handles =
          a.type == AnnotationType.line || a.type == AnnotationType.arrow
          ? [p1, p2]
          : [
              Offset(rect.left, rect.top),
              Offset(rect.right, rect.top),
              Offset(rect.left, rect.bottom),
              Offset(rect.right, rect.bottom),
            ];
      final r = 5.0 / scale;
      for (final h in handles) {
        canvas.drawCircle(h, r + 1, outline);
        canvas.drawCircle(h, r, hp);
      }
    }
  }

  /// 在原图矩形区域画固定雪花点。块起点、块坐标与导出 _applyMosaic 一致。
  void _drawSnowRect(
    Canvas canvas,
    int x1,
    int y1,
    int x2,
    int y2,
    int blockSize,
  ) {
    final left = math.min(x1, x2);
    final top = math.min(y1, y2);
    final right = math.max(x1, x2);
    final bottom = math.max(y1, y2);
    final block = math.max(2, blockSize);
    for (var by = top; by <= bottom; by += block) {
      for (var bx = left; bx <= right; bx += block) {
        final g = snowGray(bx ~/ block, by ~/ block);
        final tl = _p(bx.toDouble(), by.toDouble());
        final br = _p(
          math.min(bx + block, right + 1).toDouble(),
          math.min(by + block, bottom + 1).toDouble(),
        );
        canvas.drawRect(
          Rect.fromPoints(tl, br),
          Paint()..color = Color.fromARGB(255, g, g, g),
        );
      }
    }
  }

  /// 涂抹马赛克：沿轨迹按块填雪花点，块坐标取全局网格（与导出一致）。
  void _drawSnowStroke(Canvas canvas, Annotation a) {
    final pts = a.points;
    if (pts.length < 2) return;
    final block = math.max(2, a.mosaicBlock);
    // 收集轨迹覆盖的块坐标（按圆刷半径外扩），去重后逐块画雪花方块。
    final covered = <(int, int)>{};
    for (var i = 0; i < pts.length; i += 2) {
      final cx = pts[i];
      final cy = pts[i + 1];
      final r = a.brushRadius;
      for (var by = ((cy - r) ~/ block) * block; by <= cy + r; by += block) {
        for (var bx = ((cx - r) ~/ block) * block; bx <= cx + r; bx += block) {
          covered.add((bx, by));
        }
      }
    }
    for (final (bx, by) in covered) {
      final g = snowGray(bx ~/ block, by ~/ block);
      final tl = _p(bx.toDouble(), by.toDouble());
      final br = _p((bx + block).toDouble(), (by + block).toDouble());
      canvas.drawRect(
        Rect.fromPoints(tl, br),
        Paint()..color = Color.fromARGB(255, g, g, g),
      );
    }
  }

  /// 涂抹轨迹预览：半透明圆头粗线，半径按当前缩放折算到屏幕。
  /// 只示意覆盖范围，真实打码在导出时由 [_applyBrush] 逐像素生成。
  void _drawBrushPreview(Canvas canvas, Annotation a) {
    final pts = a.points;
    if (pts.isEmpty) return;
    final paint = Paint()
      ..color =
          (a.brushMode == BrushMode.blur
                  ? const Color(0xFF42A5F5)
                  : const Color(0xFFFF7043))
              .withValues(alpha: 0.4)
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..strokeWidth = a.brushRadius * 2 * fit.width / source.width;
    final screen = <Offset>[
      for (var i = 0; i < pts.length; i += 2)
        _p(pts[i].toDouble(), pts[i + 1].toDouble()),
    ];
    if (screen.length == 1) {
      canvas.drawCircle(
        screen.first,
        paint.strokeWidth / 2,
        paint..style = PaintingStyle.fill,
      );
      return;
    }
    canvas.drawPoints(ui.PointMode.polygon, screen, paint);
  }

  void _drawArrow(Canvas canvas, Offset p1, Offset p2, Paint paint) {
    canvas.drawLine(p1, p2, paint);
    final angle = math.atan2(p2.dy - p1.dy, p2.dx - p1.dx);
    final head = math.max(12.0, paint.strokeWidth * 4);
    final a1 = angle - math.pi / 6;
    final a2 = angle + math.pi / 6;
    canvas.drawLine(
      p2,
      p2 - Offset(math.cos(a1) * head, math.sin(a1) * head),
      paint,
    );
    canvas.drawLine(
      p2,
      p2 - Offset(math.cos(a2) * head, math.sin(a2) * head),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant _AnnotationPainter old) =>
      old.annotations != annotations ||
      old.draft != draft ||
      old.selected != selected ||
      old.scale != scale ||
      old.origin != origin ||
      old.fit != fit;
}
