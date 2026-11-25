import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:image_format_factory/core/batch/batch_executor.dart';
import 'package:image_format_factory/core/batch/batch_models.dart';
import 'package:image_format_factory/core/image/image_format.dart';

List<BatchItem> _items(int n) => List.generate(
      n,
      (i) => BatchItem(
        id: i,
        fileName: 'img$i.png',
        sourceBytes: Uint8List.fromList([i]),
      ),
    );

const _config = BatchConfig(targetFormat: ImageFormat.png);

Uint8List _bytes(int v) => Uint8List.fromList([v]);

void main() {
  group('BatchExecutor', () {
    test('全部成功时结果顺序与输入一致', () async {
      final executor = BatchExecutor(
        encode: (item, config) async => BatchEncoded(
          bytes: Uint8List.fromList([item.id]),
          width: 10,
          height: 10,
        ),
        save: (item, config, encoded) async => '/out/${item.fileName}',
      );
      final results = await executor.run(items: _items(3), config: _config);
      expect(results.length, 3);
      expect(results.every((r) => r.isSuccess), isTrue);
      expect(results.map((r) => r.item.id), [0, 1, 2]);
    });

    test('失败隔离：一项编码失败不影响其余项', () async {
      final executor = BatchExecutor(
        encode: (item, config) async {
          if (item.id == 1) return null;
          return BatchEncoded(
            bytes: Uint8List.fromList([item.id]),
            width: 10,
            height: 10,
          );
        },
        save: (item, config, encoded) async => '/out/${item.fileName}',
      );
      final results = await executor.run(items: _items(3), config: _config);
      expect(results.length, 3);
      expect(results[0].isSuccess, isTrue);
      expect(results[1].isSuccess, isFalse);
      expect(results[2].isSuccess, isTrue);
    });

    test('异常被捕获并隔离，不中断批次', () async {
      final executor = BatchExecutor(
        encode: (item, config) async {
          if (item.id == 0) throw StateError('boom');
          return BatchEncoded(bytes: _bytes(1), width: 1, height: 1);
        },
        save: (item, config, encoded) async => '/out/x',
      );
      final results = await executor.run(items: _items(2), config: _config);
      expect(results.length, 2);
      expect(results[0].isSuccess, isFalse);
      expect(results[1].isSuccess, isTrue);
    });

    test('协作式取消：取消后不再启动新项', () async {
      final token = BatchCancelToken();
      var started = 0;
      final executor = BatchExecutor(
        encode: (item, config) async {
          started++;
          return BatchEncoded(bytes: _bytes(1), width: 1, height: 1);
        },
        save: (item, config, encoded) async => '/out/x',
      );
      final results = await executor.run(
        items: _items(5),
        config: _config,
        token: token,
        // 第一项完成后取消：后续项不应再启动
        onProgress: (p) {
          if (p.done == 1) token.cancel();
        },
      );
      expect(started, 1);
      expect(results.length, 1);
    });

    test('开始前已取消则不处理任何项', () async {
      final token = BatchCancelToken()..cancel();
      var started = 0;
      final executor = BatchExecutor(
        encode: (item, config) async {
          started++;
          return BatchEncoded(bytes: _bytes(1), width: 1, height: 1);
        },
        save: (item, config, encoded) async => '/out/x',
      );
      final results = await executor.run(
        items: _items(3),
        config: _config,
        token: token,
      );
      expect(started, 0);
      expect(results, isEmpty);
    });

    test('保存返回 null（用户取消）记为失败项并继续', () async {
      final executor = BatchExecutor(
        encode: (item, config) async =>
            BatchEncoded(bytes: _bytes(1), width: 1, height: 1),
        save: (item, config, encoded) async =>
            item.id == 1 ? null : '/out/x',
      );
      final results = await executor.run(items: _items(3), config: _config);
      expect(results.length, 3);
      expect(results[1].isSuccess, isFalse);
      expect(results[2].isSuccess, isTrue);
    });

    test('进度回调次数正确，fraction 单调到 1', () async {
      final fractions = <double>[];
      final executor = BatchExecutor(
        encode: (item, config) async =>
            BatchEncoded(bytes: _bytes(1), width: 1, height: 1),
        save: (item, config, encoded) async => '/out/x',
      );
      await executor.run(
        items: _items(3),
        config: _config,
        onProgress: (p) => fractions.add(p.fraction),
      );
      expect(fractions.length, 5); // 起始 + 3 项 + 结束
      expect(fractions.last, 1.0);
    });
  });
}
