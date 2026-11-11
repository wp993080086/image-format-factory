import 'package:flutter_test/flutter_test.dart';
import 'package:pixel_forge/core/log/log_ring_buffer.dart';

void main() {
  group('LogRingBuffer 容量控制', () {
    test('未超上限时全部保留', () {
      final buffer = LogRingBuffer(maxBytes: 100);
      buffer
        ..add('a')
        ..add('b');

      expect(buffer.lines, ['a', 'b']);
      expect(buffer.byteCount, 2);
      expect(buffer.length, 2);
      expect(buffer.isEmpty, isFalse);
    });

    test('超出上限时从头淘汰最旧的行', () {
      // 每行 5 字节，容量刚好装 2 行
      final buffer = LogRingBuffer(maxBytes: 10);
      buffer
        ..add('aaaaa')
        ..add('bbbbb');
      expect(buffer.byteCount, 10);

      buffer.add('cc');

      expect(buffer.lines, ['bbbbb', 'cc']);
      expect(buffer.byteCount, 7);
    });

    test('按 UTF-8 字节计容量，中文一字 3 字节', () {
      final buffer = LogRingBuffer(maxBytes: 4);
      buffer.add('中');
      expect(buffer.byteCount, 3);

      // 6 > 4，淘汰最旧的 '中'
      buffer.add('文');

      expect(buffer.lines, ['文']);
      expect(buffer.byteCount, 3);
    });

    test('单行本身超上限时整行丢弃，不留半行', () {
      final buffer = LogRingBuffer(maxBytes: 4);
      buffer
        ..add('keep')
        ..add('这条日志本身就超过上限了');

      expect(buffer.isEmpty, isTrue);
      expect(buffer.byteCount, 0);
    });

    test('text 以换行拼接，clear 清空计数', () {
      final buffer = LogRingBuffer(maxBytes: 100);
      buffer
        ..add('1')
        ..add('2');
      expect(buffer.text, '1\n2');

      buffer.clear();

      expect(buffer.isEmpty, isTrue);
      expect(buffer.byteCount, 0);
      expect(buffer.text, isEmpty);
    });

    test('lines 是只读视图，外部修改不影响内部状态', () {
      final buffer = LogRingBuffer(maxBytes: 100)..add('a');

      expect(() => buffer.lines.add('b'), throwsUnsupportedError);
      expect(buffer.lines, ['a']);
    });

    test('默认上限为 2MB（PRD 十六.2）', () {
      expect(LogRingBuffer().maxBytes, 2 * 1024 * 1024);
    });
  });
}
