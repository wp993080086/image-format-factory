import 'package:image/image.dart' as img;

/// 从已解码的 ICO 中取像素数最大的那一帧作为位图源（PRD 4.1）。
///
/// ICO 目录项顺序不保证（主流工具按尺寸升序写，但规范未强制），而
/// `IcoDecoder` 恰好把目录首项当作主图 —— 直接使用会拿到 16×16，
/// 白丢 256×256 的细节，重新打包时更是把多尺寸图标压成单尺寸。
///
/// **不可用于非 ICO 动图**：GIF / APNG 的帧尺寸未必一致，且 PRD 4.1 对它们
/// 的要求是「取指定帧」。调用方须先用 `ImageFormatDetector.isIco` 判定。
img.Image largestIcoFrame(img.Image decoded) {
  final frames = decoded.frames;
  if (frames.length <= 1) return decoded;

  var best = frames.first;
  for (final frame in frames.skip(1)) {
    if (frame.width * frame.height > best.width * best.height) {
      best = frame;
    }
  }
  return best;
}
