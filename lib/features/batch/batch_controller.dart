import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/batch/batch_executor.dart';
import '../../core/batch/batch_models.dart';
import '../../core/di/providers.dart';
import '../../core/image/image_format.dart';
import '../../core/log/app_logger.dart';
import '../../services/batch/batch_pipeline.dart';
import '../../services/file/import_service.dart';

/// 批量页阶段。
enum BatchStage { empty, picking, configuring, running, done }

/// 批量页状态。
class BatchState {
  const BatchState({
    this.stage = BatchStage.empty,
    this.items = const [],
    this.config = const BatchConfig(),
    this.progress,
    this.results = const [],
    this.skippedDuplicates = 0,
  });

  final BatchStage stage;
  final List<BatchItem> items;
  final BatchConfig config;
  final BatchProgress? progress;
  final List<BatchItemResult> results;

  /// 最近一次选图因重复被跳过的张数（追加去重提示）。
  final int skippedDuplicates;

  int get successCount => results.where((r) => r.isSuccess).length;
  int get failCount => results.length - successCount;
  bool get busy => stage == BatchStage.picking || stage == BatchStage.running;

  BatchState copyWith({
    BatchStage? stage,
    List<BatchItem>? items,
    BatchConfig? config,
    BatchProgress? progress,
    List<BatchItemResult>? results,
    int? skippedDuplicates,
  }) {
    return BatchState(
      stage: stage ?? this.stage,
      items: items ?? this.items,
      config: config ?? this.config,
      progress: progress ?? this.progress,
      results: results ?? this.results,
      skippedDuplicates: skippedDuplicates ?? this.skippedDuplicates,
    );
  }
}

/// 批量任务控制器。
class BatchController extends Notifier<BatchState> {
  BatchCancelToken? _cancelToken;

  @override
  BatchState build() => const BatchState();

  /// 选多图 → 追加到现有列表（已选的不会被替换）。
  /// 去重依据：文件名 + 内容长度 + 折叠哈希（[_dedupeKey]）相同才算重复，
  /// 即拍板的"同名且同内容"语义；同名不同内容会都保留。
  Future<void> pickImages() async {
    if (state.busy) return;
    state = state.copyWith(
      stage: BatchStage.picking,
      progress: null,
      results: const [],
    );
    final imports = await ref.read(importServiceProvider).pickImages();
    if (imports.isEmpty) {
      state = state.copyWith(
        stage: state.items.isEmpty ? BatchStage.empty : BatchStage.configuring,
        skippedDuplicates: 0,
      );
      return;
    }
    final items = List<BatchItem>.from(state.items);
    var nextId = items.isEmpty
        ? 0
        : items.map((e) => e.id).reduce(math.max) + 1;
    final seen = <String>{
      for (final i in items) _dedupeKey(i.fileName, i.sourceBytes),
    };
    var skipped = 0;
    for (final r in imports) {
      final key = _dedupeKey(r.fileName, r.bytes);
      if (!seen.add(key)) {
        skipped++;
        continue;
      }
      items.add(
        BatchItem(
          id: nextId++,
          fileName: r.fileName,
          sourceBytes: r.bytes,
          animated: r.isAnimated,
        ),
      );
    }
    state = state.copyWith(
      stage: BatchStage.configuring,
      items: items,
      skippedDuplicates: skipped,
    );
  }

  /// 去重键：文件名 + 内容长度 + 折叠哈希，避免同名不同内容被误判。
  static String _dedupeKey(String name, List<int> bytes) {
    var h = 0;
    for (final b in bytes) {
      h = ((h << 5) - h + b) & 0x7fffffff;
    }
    return '$name:${bytes.length}:$h';
  }

  /// 从已选列表移除一张（按 id，避免重名误删）。
  void removeItem(int id) {
    if (state.busy) return;
    final items = state.items.where((i) => i.id != id).toList();
    state = state.copyWith(
      items: items,
      stage: items.isEmpty ? BatchStage.empty : BatchStage.configuring,
      skippedDuplicates: 0,
    );
  }

  /// 更新配置。
  void updateConfig(BatchConfig config) {
    if (state.busy) return;
    state = state.copyWith(config: config);
  }

  /// 执行批量任务。
  Future<void> run() async {
    if (state.items.isEmpty || state.busy) return;
    final token = BatchCancelToken();
    _cancelToken = token;
    state = state.copyWith(stage: BatchStage.running, results: const []);

    final pipeline = BatchPipeline(
      encodeService: ref.read(encodeServiceProvider),
      exportService: ref.read(exportServiceProvider),
    );
    try {
      await pipeline.prepareExport();
    } catch (e, st) {
      // 选目录失败不影响导出：回落到原来的逐张保存通道。
      AppLogger.warn(
        '批量选择输出目录失败，改为逐张保存',
        name: 'batch',
        error: e,
        stackTrace: st,
      );
    }
    final results = await pipeline.executor().run(
      items: state.items,
      config: state.config,
      token: token,
      onProgress: (p) {
        if (state.stage == BatchStage.running) {
          state = state.copyWith(progress: p, results: p.results);
        }
      },
    );
    _cancelToken = null;
    state = state.copyWith(stage: BatchStage.done, results: results);
  }

  /// 协作式取消。
  void cancel() => _cancelToken?.cancel();

  /// 回到空态，准备下一批。
  void reset() => state = const BatchState();

  /// 批量目标格式是否受当前端能力支持（由 UI 决定展示哪些格式选项）。
  bool canExport(ImageFormat format) =>
      ref.read(capabilitiesProvider).canExport(format);

  /// 当前端能否逐帧重编码动图（决定动图开关是否展示）。
  bool get canExportAnimation =>
      ref.read(capabilitiesProvider).animatedReencode;

  /// 本批里是否有动图源，只有动图源才需要动图导出开关。
  bool get hasAnimatedItem => state.items.any((item) => item.animated);
}

final batchControllerProvider = NotifierProvider<BatchController, BatchState>(
  BatchController.new,
);
