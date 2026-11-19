import 'dart:typed_data';

import '../../core/batch/batch_executor.dart';
import '../../core/batch/batch_models.dart';
import '../../core/image/encode_service.dart';
import '../../core/image/image_format.dart';
import '../../core/image/target_size_compress.dart';
import '../file/export_service.dart';

/// 把 [EncodeService] 与 [ExportService] 适配成批量执行器所需的回调。
///
/// 单独成类而非塞进 controller：回调逻辑可独立单测，controller 只管状态。
class BatchPipeline {
  const BatchPipeline({
    required this.encodeService,
    required this.exportService,
  });

  final EncodeService encodeService;
  final ExportService exportService;

  /// 编码回调：构造 [EncodeRequest]，若配置了目标体积再做质量二分。
  Future<BatchEncoded?> encode(BatchItem item, BatchConfig config) async {
    final result = await encodeService.encode(
      EncodeRequest(
        sourceBytes: item.sourceBytes,
        format: config.targetFormat,
        quality: config.quality,
        icoSizes: config.icoSizes,
        crop: config.crop,
        cropCircle: config.circleCrop,
        resize: config.resize,
        jpegChroma: config.jpegChroma,
        pngLevel: config.pngLevel,
        pngPalette: config.pngPalette,
        exportAnimation: config.exportAnimation && item.animated,
        avifQuality: config.avifQuality,
        colorAdjust: config.colorAdjust,
        watermark: config.watermark,
        annotations: config.annotations,
      ),
    );
    if (result == null) return null;

    // 目标体积压缩：仅对有质量参数的有损格式生效。
    // 二分搜索会重新编码多次，取回满足目标的最高画质版本。
    if (config.targetKb != null && _isLossy(config.targetFormat)) {
      final compressed = await compressToTargetSize(
        encode: (quality) async {
          final r = await encodeService.encode(
            EncodeRequest(
              sourceBytes: item.sourceBytes,
              format: config.targetFormat,
              quality: quality,
              icoSizes: config.icoSizes,
              crop: config.crop,
              cropCircle: config.circleCrop,
              resize: config.resize,
              jpegChroma: config.jpegChroma,
              pngLevel: config.pngLevel,
              pngPalette: config.pngPalette,
              colorAdjust: config.colorAdjust,
              watermark: config.watermark,
              annotations: config.annotations,
            ),
          );
          return r?.bytes ?? const <int>[];
        },
        targetBytes: targetKbToBytes(config.targetKb!),
      );
      if (compressed != null) {
        return BatchEncoded(
          bytes: Uint8List.fromList(compressed.bytes),
          width: result.size.width,
          height: result.size.height,
        );
      }
    }

    return BatchEncoded(
      bytes: result.bytes,
      width: result.size.width,
      height: result.size.height,
    );
  }

  /// 保存回调：按端差异写盘，用户取消返回 null。
  Future<String?> save(
    BatchItem item,
    BatchConfig config,
    BatchEncoded encoded,
  ) async {
    final name = buildExportFileName(
      sourceFileName: item.fileName,
      format: config.targetFormat,
      quality: config.quality,
      width: encoded.width,
      height: encoded.height,
    );
    final result = await exportService.save(
      ExportRequest(
        suggestedName: name,
        bytes: encoded.bytes,
        format: config.targetFormat,
      ),
    );
    return result?.savedPath;
  }

  /// 构造绑定好本服务回调的执行器。
  BatchExecutor executor() => BatchExecutor(encode: encode, save: save);

  static bool _isLossy(ImageFormat format) =>
      format == ImageFormat.jpeg ||
      format == ImageFormat.webp ||
      format == ImageFormat.avif;
}
