import 'dart:collection';
import 'dart:math' as math;

import 'package:image/image.dart' as img;

import 'fonts/cjk_24.dart';

/// 中文文字渲染适配层。
///
/// `image` 包自带的 arial 位图字体只有 ASCII，中文会被静默跳过。
/// 本模块提供基于内嵌 Noto Sans SC 点阵（[cjk24]，GB2312 一级字库 3885 字）
/// 的中文渲染，纯 Dart、可在后台 Isolate 使用（符合项目架构铁律）。
///
/// 字号策略：字库只有 24px 基准一档。为避免把全部 3885 个字形都缩放一遍，
/// [fontFor] 只缩放给定文本中实际出现的字符，并按字号缓存结果。
class CjkText {
  CjkText._();

  /// 字号上限：允许文字随高分辨率原图放大到接近图片宽度。
  /// 字形放大只在导出时发生，度量走线性换算，不生成大字形。
  static const int maxFontSize = 2048;

  /// 按字号缓存的字体实例（key 为字号），只缓存常规字号。
  /// 大字号若逐帧缓存会在拖动过程中堆积大量位图，因此用完即弃。
  static final Map<int, img.BitmapFont> _cache = HashMap();
  static const int _cacheMaxFontSize = 200;

  /// 返回可用于 `img.drawString` 的字体：字号等于 24 时直接返回基准字体，
  /// 否则构造一份只含所需字形缩放版的字体。
  ///
  /// 缓存粒度是「字号 → 一份字体实例」：同一字号的所有文本共享实例，
  /// 遇到尚未缓存的字形时按需往里补充（[_coversAll] 判断覆盖）。
  /// 字库总量有限，累积不会无限增长。
  static img.BitmapFont fontFor(String text, int fontSize) {
    final size = fontSize.clamp(6, maxFontSize);
    if (size == 24) return cjk24;

    // 大字号（>200）只用于导出，用完即弃；若进缓存，拖动逐帧生成的不同字号
    // 会堆积大量放大位图，真机很快 OOM。
    final cached = size <= _cacheMaxFontSize ? _cache[size] : null;
    if (cached != null && _coversAll(cached, text)) return cached;

    final font = cached ?? _cloneShell(cjk24, size);
    final scale = size / 24.0;
    for (final code in text.codeUnits) {
      if (font.characters.containsKey(code)) continue;
      final base = cjk24.characters[code];
      if (base == null) continue; // 字库外的字（生僻字/emoji）仍由 drawString 跳过
      font.characters[code] = _scaleGlyph(base, scale);
    }
    if (size <= _cacheMaxFontSize) _cache[size] = font;
    return font;
  }

  static bool _coversAll(img.BitmapFont font, String text) {
    for (final code in text.codeUnits) {
      if (!font.characters.containsKey(code)) return false;
    }
    return true;
  }

  static img.BitmapFont _cloneShell(img.BitmapFont base, int size) {
    // fromFnt('') 产生空壳，再补齐度量信息（drawString 用 base 处理未知字符）。
    final shell = img.BitmapFont.fromFnt('', img.Image(width: 1, height: 1));
    final scale = size / 24.0;
    shell.face = base.face;
    shell.size = size;
    shell.base = (base.base * scale).round();
    shell.lineHeight = (base.lineHeight * scale).round();
    shell.scaleW = base.scaleW;
    shell.scaleH = base.scaleH;
    shell.pages = 1;
    return shell;
  }

  static img.BitmapFontCharacter _scaleGlyph(
    img.BitmapFontCharacter base,
    double scale,
  ) {
    final w = (base.width * scale).round().clamp(1, maxFontSize);
    final h = (base.height * scale).round().clamp(1, maxFontSize);
    final scaled = img.copyResize(
      base.image,
      width: w,
      height: h,
      interpolation: img.Interpolation.linear,
    );
    final ch = img.BitmapFontCharacter(
      base.id,
      w,
      h,
      (base.xOffset * scale).round(),
      (base.yOffset * scale).round(),
      (base.xAdvance * scale).round().clamp(1, maxFontSize),
      base.page,
      base.channel,
    );
    // BitmapFontCharacter.image 是 final，构造后按缩放结果逐像素写回。
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        ch.image.setPixel(x, y, scaled.getPixel(x, y));
      }
    }
    return ch;
  }

  /// 按字号线性换算字库基准度量，不生成放大位图。
  ///
  /// 拖动缩放每帧都要测量，若走 [fontFor] 会反复缩放整张字形位图导致卡顿。
  /// 缩放规则与 [_scaleGlyph] 一致，保证框与导出字形对齐。
  static ({int advance, int height, int inkHeight, int yOffset}) _metrics(
    String text,
    int fontSize,
  ) {
    final scale = fontSize.clamp(6, maxFontSize) / 24.0;
    var advance = 0;
    var height = 0;
    var inkHeight = 0;
    var yOffset = 0;
    for (final code in text.codeUnits) {
      final base = cjk24.characters[code];
      if (base == null) {
        advance += (cjk24.base * scale).round() ~/ 2;
        continue;
      }
      final a = (base.xAdvance * scale).round().clamp(1, maxFontSize);
      final h = (base.height * scale).round().clamp(1, maxFontSize);
      final yo = (base.yOffset * scale).round();
      advance += a;
      if (h > height) height = h;
      if (h + yo > inkHeight) inkHeight = h + yo;
      if (yo > yOffset) yOffset = yo;
    }
    return (
      advance: advance,
      height: height,
      inkHeight: inkHeight,
      yOffset: yOffset,
    );
  }

  /// 测量文本像素宽度（用于水印定位/标注命中区）。
  static int measureWidth(String text, int fontSize) =>
      _metrics(text, fontSize).advance;

  /// 测量文本高度（取最大字形高度，近似行高）。
  static int measureHeight(String text, int fontSize) {
    final h = _metrics(text, fontSize).height;
    return h == 0 ? fontSize : h;
  }

  /// 测量字形实际占位高度（height + yOffset），用于给渲染画布留白。
  ///
  /// 与 [measureHeight] 不同：这里把字形相对基线的 yOffset 一并计入，
  /// 用于给渲染画布留白，避免字形因偏移超出画布被裁切。
  static int measureInkHeight(String text, int fontSize) =>
      _metrics(text, fontSize).inkHeight;

  /// 字形相对绘制起点的最大纵向偏移，供预览按导出点阵的基线对齐。
  static int maxYOffset(String text, int fontSize) =>
      _metrics(text, fontSize).yOffset;

  /// 点阵字形在标注框内垂直居中时，绘制起点相对框顶部的偏移。
  ///
  /// 框高取 [measureInkHeight]（与创建/缩放时一致），字形顶部还要叠加
  /// [maxYOffset]，这里把两者抵消，保证上下留白相等。
  static int centeredYOffset(String text, int fontSize) {
    final boxHeight = math.max(measureInkHeight(text, fontSize), fontSize);
    final glyphHeight = measureHeight(text, fontSize);
    return ((boxHeight - glyphHeight) / 2 - maxYOffset(text, fontSize)).round();
  }
}
