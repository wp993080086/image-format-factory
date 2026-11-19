import 'dart:async';
import 'dart:typed_data';

import 'batch_models.dart';

/// 协作式取消令牌（PRD v0.5：批量任务可取消）。
///
/// 不抢占正在进行的编码，而是在每个检查点（每项开始前、每项完成后）判断，
/// 保证取消后不再启动新项，已开始的项跑完当前一步即停。
class BatchCancelToken {
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void cancel() => _cancelled = true;
}

/// 编码单项的回调：返回编码后的字节与最终尺寸；返回 null 视为该项编码失败。
typedef BatchEncode = Future<BatchEncoded?> Function(
  BatchItem item,
  BatchConfig config,
);

/// 保存单项的回调：返回保存位置；用户取消时返回 null。
typedef BatchSave = Future<String?> Function(
  BatchItem item,
  BatchConfig config,
  BatchEncoded encoded,
);

/// 编码输出。
class BatchEncoded {
  const BatchEncoded({
    required this.bytes,
    required this.width,
    required this.height,
  });

  final Uint8List bytes;
  final int width;
  final int height;
}

/// 批量任务执行器。
///
/// - 串行处理，避免多图同时解码导致移动端 OOM；
/// - 失败隔离：单项异常只记入该项结果，不影响后续项；
/// - 协作式取消：每个检查点响应 [token]，取消后不再启动新项；
/// - 逐项进度：通过 [onProgress] 推送快照，UI 据此刷新。
class BatchExecutor {
  const BatchExecutor({
    required this.encode,
    required this.save,
  });

  final BatchEncode encode;
  final BatchSave save;

  Future<List<BatchItemResult>> run({
    required List<BatchItem> items,
    required BatchConfig config,
    BatchCancelToken? token,
    void Function(BatchProgress)? onProgress,
  }) async {
    final results = <BatchItemResult>[];

    void emit(String? current) {
      onProgress?.call(
        BatchProgress(
          done: results.length,
          total: items.length,
          currentName: current,
          results: List.unmodifiable(results),
        ),
      );
    }

    emit(items.isEmpty ? null : items.first.fileName);
    for (final item in items) {
      if (token?.isCancelled ?? false) break;

      try {
        final encoded = await encode(item, config);
        if (encoded == null) {
          results.add(
            BatchItemResult.failure(item: item, error: StateError('编码失败')),
          );
          emit(null);
          continue;
        }
        if (token?.isCancelled ?? false) break;

        final path = await save(item, config, encoded);
        if (path == null) {
          // 用户取消单文件保存：记为失败项，继续处理其余
          results.add(
            BatchItemResult.failure(item: item, error: StateError('已取消保存')),
          );
        } else {
          results.add(
            BatchItemResult.success(
              item: item,
              savedPath: path,
              outputBytes: encoded.bytes,
            ),
          );
        }
      } catch (e) {
        // 失败隔离：任何异常只落到当前项
        results.add(BatchItemResult.failure(item: item, error: e));
      }
      emit(null);
    }

    emit(null);
    return List.unmodifiable(results);
  }
}
