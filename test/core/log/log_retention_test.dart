import 'package:flutter_test/flutter_test.dart';
import 'package:pixel_forge/core/log/log_retention.dart';

void main() {
  group('会话日志命名', () {
    test('按固定宽度零填充，字典序即时间序', () {
      final names = [
        buildLogFileName(DateTime(2026, 11, 11, 9, 5, 3)),
        buildLogFileName(DateTime(2026, 11, 11, 10, 5, 3)),
      ];

      expect(names[0], 'pf-20261111-090503.log');
      // 零填充后，较早的会话字典序更小
      expect(names[0].compareTo(names[1]) < 0, isTrue);
    });

    test('只认本应用的日志文件', () {
      expect(isLogFileName('pf-20261111-090503.log'), isTrue);
      expect(isLogFileName('other.log'), isFalse);
      expect(isLogFileName('pf-20261111-090503.txt'), isFalse);
    });
  });

  group('保留策略', () {
    final files = [
      'pf-20261111-090000.log',
      'pf-20261111-100000.log',
      'pf-20261111-110000.log',
      'pf-20261111-120000.log',
      'pf-20261111-130000.log',
    ];

    test('未超出保留份数时不删除', () {
      expect(logsToPrune(files.take(3).toList()), isEmpty);
    });

    test('超出份数时删除最旧的，保留最近 3 个', () {
      expect(logsToPrune(files), [
        'pf-20261111-090000.log',
        'pf-20261111-100000.log',
      ]);
    });

    test('非日志文件不参与统计，更不会被删', () {
      final mixed = [...files, 'notes.txt', 'pf-bak.log.bak'];

      final pruned = logsToPrune(mixed);

      expect(pruned, isNot(contains('notes.txt')));
      expect(pruned, isNot(contains('pf-bak.log.bak')));
      expect(pruned.length, 2);
    });

    test('recentLogFiles 最新在前，数量受保留份数约束', () {
      expect(recentLogFiles(files), [
        'pf-20261111-130000.log',
        'pf-20261111-120000.log',
        'pf-20261111-110000.log',
      ]);
      expect(recentLogFiles(files.take(2).toList()).length, 2);
    });
  });
}
