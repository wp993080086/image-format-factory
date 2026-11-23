import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixel_forge/core/image/image_format.dart';
import 'package:pixel_forge/core/platform/app_platform.dart';
import 'package:pixel_forge/core/platform/capabilities.dart';
import 'package:pixel_forge/features/batch/batch_controller.dart';
import 'package:pixel_forge/services/file/import_service.dart';

/// 按预定批次返回选图结果的替身，避免测试依赖系统文件选择器。
class _ScriptedImportService extends ImportService {
  _ScriptedImportService(this._batches)
    : super(PlatformCapabilities.of(AppTarget.windows));

  final List<List<ImportResult>> _batches;
  int _call = 0;

  @override
  Future<List<ImportResult>> pickImages() async {
    if (_call >= _batches.length) return const [];
    return _batches[_call++];
  }
}

ImportResult _img(String name, List<int> bytes) => ImportResult(
  fileName: name,
  bytes: Uint8List.fromList(bytes),
  format: ImageFormat.png,
  isAnimated: false,
  extensionMismatch: false,
);

ProviderContainer _containerWith(_ScriptedImportService service) =>
    ProviderContainer(
      overrides: [importServiceProvider.overrideWithValue(service)],
    );

void main() {
  test('再次选图追加而非替换，且 id 不与已有项冲突', () async {
    final container = _containerWith(
      _ScriptedImportService([
        [
          _img('a.png', [1]),
          _img('b.png', [2]),
        ],
        [
          _img('c.png', [3]),
        ],
      ]),
    );
    final c = container.read(batchControllerProvider.notifier);

    await c.pickImages();
    expect(c.state.items.length, 2);
    await c.pickImages();
    expect(c.state.items.length, 3, reason: '第二次选图应追加，不替换');
    expect(c.state.items.map((e) => e.fileName), ['a.png', 'b.png', 'c.png']);
    expect(c.state.items.map((e) => e.id).toSet().length, 3, reason: 'id 必须唯一');
  });

  test('同名同内容判为重复并跳过；同名不同内容保留', () async {
    final container = _containerWith(
      _ScriptedImportService([
        [
          _img('a.png', [1, 2, 3]),
        ],
        [
          _img('a.png', [1, 2, 3]), // 完全重复
          _img('a.png', [9, 8, 7]), // 同名不同内容
        ],
      ]),
    );
    final c = container.read(batchControllerProvider.notifier);

    await c.pickImages();
    await c.pickImages();
    expect(c.state.items.length, 2, reason: '跳过完全重复，保留同名不同内容');
    expect(c.state.items.last.sourceBytes, [9, 8, 7]);
    expect(c.state.skippedDuplicates, 1, reason: '提示应记录跳过张数');
  });

  test('删除单张后其余保留；删空回到 empty 态', () async {
    final container = _containerWith(
      _ScriptedImportService([
        [
          _img('a.png', [1]),
          _img('b.png', [2]),
        ],
      ]),
    );
    final c = container.read(batchControllerProvider.notifier);

    await c.pickImages();
    final keepId = c.state.items.last.id;
    c.removeItem(c.state.items.first.id);
    expect(c.state.items.length, 1);
    expect(c.state.items.single.id, keepId);
    expect(c.state.stage, BatchStage.configuring);

    c.removeItem(keepId);
    expect(c.state.items, isEmpty);
    expect(c.state.stage, BatchStage.empty);
  });
}
