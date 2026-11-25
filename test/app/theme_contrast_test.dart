import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_format_factory/app/theme.dart';

/// WCAG 2.1 相对亮度（sRGB 线性化后按系数加权）。
double _luminance(Color c) {
  double channel(double v) =>
      v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b);
}

/// WCAG 2.1 对比度，返回 1.0~21.0。
double contrastRatio(Color a, Color b) {
  final la = _luminance(a);
  final lb = _luminance(b);
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

/// 配色对比度守卫（PRD 九.6）。
///
/// 主题是 `ColorScheme.fromSeed` 生成的，看起来「Material 默认应该够」，
/// 但换 seed 色、升 SDK 都可能让某个配对掉到阈值下而无人察觉。这里把
/// 规范里的 4.5 / 3 两条线钉死，改主题时红了就知道哪一项不够。
void main() {
  final scheme = AppTheme.light().colorScheme;

  /// 正文：4.5:1（WCAG AA 普通文本）
  group('正文对比度 ≥ 4.5:1', () {
    void expectText(Color fg, Color bg, String label) {
      final ratio = contrastRatio(fg, bg);
      expect(
        ratio,
        greaterThanOrEqualTo(4.5),
        reason: '$label 仅 ${ratio.toStringAsFixed(2)}:1',
      );
    }

    test('主文字压在各级背景上', () {
      expectText(scheme.onSurface, scheme.surface, 'onSurface / surface');
      expectText(
        scheme.onSurface,
        scheme.surfaceContainer,
        'onSurface / surfaceContainer',
      );
      expectText(
        scheme.onSurface,
        scheme.surfaceContainerHighest,
        'onSurface / surfaceContainerHighest',
      );
    });

    test('次要文字（提示、单位、说明）', () {
      expectText(
        scheme.onSurfaceVariant,
        scheme.surface,
        'onSurfaceVariant / surface',
      );
      expectText(
        scheme.onSurfaceVariant,
        scheme.surfaceContainerHighest,
        'onSurfaceVariant / surfaceContainerHighest',
      );
    });

    test('实心按钮与选中态', () {
      expectText(scheme.onPrimary, scheme.primary, 'onPrimary / primary');
      expectText(
        scheme.onPrimaryContainer,
        scheme.primaryContainer,
        'onPrimaryContainer / primaryContainer',
      );
      expectText(
        scheme.onSecondaryContainer,
        scheme.secondaryContainer,
        'onSecondaryContainer / secondaryContainer',
      );
    });

    test('错误态', () {
      expectText(scheme.onError, scheme.error, 'onError / error');
      expectText(
        scheme.onErrorContainer,
        scheme.errorContainer,
        'onErrorContainer / errorContainer',
      );
    });
  });

  /// 控件与非文本图形：3:1（WCAG 1.4.11）
  group('控件对比度 ≥ 3:1', () {
    test('输入框 / 卡片 / 未选中描边', () {
      final ratio = contrastRatio(scheme.outline, scheme.surface);
      expect(
        ratio,
        greaterThanOrEqualTo(3.0),
        reason: 'outline / surface 仅 ${ratio.toStringAsFixed(2)}:1',
      );
    });

    test('强调色本身作为图形元素（进度、选中指示）', () {
      final ratio = contrastRatio(scheme.primary, scheme.surface);
      expect(ratio, greaterThanOrEqualTo(3.0));
    });
  });

  /// `outlineVariant` 在 Material 3 里是 1.6:1 左右的装饰色，**不用于**
  /// 有语义的控件边界。当前代码里它只由 `Divider` 默认取用（首页入口分隔），
  /// 属于纯装饰，不受 1.4.11 约束。这条用例是提醒：一旦有人拿它画输入框
  /// 或卡片边框，就必须改成 `outline`。
  test('outlineVariant 低对比度是有意为之，只允许装饰性使用', () {
    final ratio = contrastRatio(scheme.outlineVariant, scheme.surface);
    expect(
      ratio,
      lessThan(3.0),
      reason: '若该值升到 3:1 以上，说明主题被换过，需重新核对视觉层级',
    );
  });
}
