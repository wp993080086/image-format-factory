import 'dart:math' as math;

/// 按目标体积压缩的结果。
class TargetSizeResult {
  const TargetSizeResult({
    required this.bytes,
    required this.quality,
    required this.sizeBytes,
    required this.hitTarget,
  });

  final List<int> bytes;
  final int quality;
  final int sizeBytes;

  /// 是否达到了目标（true=体积 ≤ 目标；false=最低质量仍然超限）。
  final bool hitTarget;
}

/// 按目标体积压缩：对质量做二分搜索，找到满足 `体积 ≤ 目标` 的最高画质。
///
/// 适用于有质量参数的有损格式（JPEG / WebP / AVIF）。PNG 无损、质量参数不
/// 改变体积，调用方不应使用它——可用 [FormatEncoders] 侧判断。
///
/// [encode] 为给定质量返回编码字节；必须随质量单调不减体积（有损编码的普遍
/// 性质）。[targetBytes] 为目标上限；[minQuality]/[maxQuality] 为搜索区间。
///
/// 二分收敛后返回最后一个满足目标的字节；若连最低质量都超限，返回最低质量
/// 的产物并置 [TargetSizeResult.hitTarget] 为 false，由 UI 提示用户。
Future<TargetSizeResult?> compressToTargetSize({
  required Future<List<int>> Function(int quality) encode,
  required int targetBytes,
  int minQuality = 1,
  int maxQuality = 100,
  int maxIterations = 8,
}) async {
  if (targetBytes <= 0 || minQuality > maxQuality) return null;

  // 先探最低质量：还超限则无解，直接返回最低质量结果。
  final lowBytes = await encode(minQuality);
  if (lowBytes.length > targetBytes) {
    return TargetSizeResult(
      bytes: lowBytes,
      quality: minQuality,
      sizeBytes: lowBytes.length,
      hitTarget: false,
    );
  }

  // 再探最高质量：满足则直接用最高画质。
  final highBytes = await encode(maxQuality);
  if (highBytes.length <= targetBytes) {
    return TargetSizeResult(
      bytes: highBytes,
      quality: maxQuality,
      sizeBytes: highBytes.length,
      hitTarget: true,
    );
  }

  // 在 [满足的 low, 超限的 high] 之间二分，找满足目标的最高画质。
  var bestQ = minQuality;
  var bestBytes = lowBytes;
  var lo = minQuality;
  var hi = maxQuality;
  var iter = 0;
  while (lo < hi && iter++ < maxIterations) {
    final mid = lo + ((hi - lo) ~/ 2);
    final bytes = await encode(mid);
    if (bytes.length <= targetBytes) {
      bestQ = mid;
      bestBytes = bytes;
      lo = mid + 1;
    } else {
      hi = mid;
    }
  }

  return TargetSizeResult(
    bytes: bestBytes,
    quality: bestQ,
    sizeBytes: bestBytes.length,
    hitTarget: true,
  );
}

/// 把 KB 目标换算为字节（1KB = 1024B）。
int targetKbToBytes(int kb) => math.max(1, kb) * 1024;
