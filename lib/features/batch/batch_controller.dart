import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/batch/batch_executor.dart';
import '../../core/batch/batch_models.dart';
import '../../core/di/providers.dart';
import '../../core/image/image_format.dart';
import '../../services/batch/batch_pipeline.dart';
import '../../services/file/import_service.dart';

/// 批量页阶段。
enum BatchStage {
  empty,
  picking,
  configuring,
  running,
  done,
}

/// 批量页状态。
class BatchState {
  const BatchState({
    this.stage = BatchStage.empty,
    this.items = const [],
    this.config = const BatchConfig(),
    this.progress,
    this.results = const [],
  });

  final BatchStage stage;
  final List<BatchItem> items;
  final BatchConfig config;
  final BatchProgress? progress;
  final List<BatchItemResult> results;

  int get successCount => results.where((r) => r.isSuccess).length;
  int get failCount => results.length - successCount;
  bool get busy => stage == BatchStage.picking || stage == BatchStage.running;

  BatchState copyWith({
    BatchStage? stage,
    List<BatchItem>? items,
    BatchConfig? config,
    BatchProgress? progress,
    List<BatchItemResult>? results,
  }) {
    return BatchState(
      stage: stage ?? this.stage,
      items: items ?? this.items,
      config: config ?? this.config,
      progress: progress ?? this.progress,
      results: results ?? this.results,
    );
  }
}

/// 批量任务控制器。
class BatchController extends Notifier<BatchState> {
  BatchCancelToken? _cancelToken;

  @override
  BatchState build() => const BatchState();

  /// 选多图 → 进入配置态。
  Future<void> pickImages() async {
    if (state.busy) return;
    state = state.copyWith(stage: BatchStage.picking, progress: null, results: const []);
    final imports = await ref.read(importServiceProvider).pickImages();
    if (imports.isEmpty) {
      state = state.copyWith(stage: BatchStage.empty);
      return;
    }
    final items = <BatchItem>[];
    for (var i = 0; i < imports.length; i++) {
      final r = imports[i];
      items.add(
        BatchItem(
          id: i,
          fileName: r.fileName,
          sourceBytes: r.bytes,
          animated: r.isAnimated,
        ),
      );
    }
    state = state.copyWith(stage: BatchStage.configuring, items: items);
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
}

final batchControllerProvider =
    NotifierProvider<BatchController, BatchState>(BatchController.new);
