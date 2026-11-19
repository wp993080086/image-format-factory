/// Windows 端 AVIF 编解码：调用随包分发的 libavif 官方 CLI（avifenc / avifdec）。
///
/// 用 CLI 而非 FFI 调 libavif.dll：官方 release 只提供静态链接的可执行程序，
/// 零 DLL 依赖链、随包即用；源码自建 DLL 需 nasm/perl 且要单独分发 aom/dav1d。
/// Process 在后台 Isolate 内可用，符合"重活在子 Isolate"的约束。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// CLI 调用结果。
class AvifCliResult {
  const AvifCliResult._(this.bytes, this.error);

  final Uint8List? bytes;
  final String? error;
  bool get isSuccess => bytes != null;

  factory AvifCliResult.ok(Uint8List bytes) => AvifCliResult._(bytes, null);
  factory AvifCliResult.fail(String error) => AvifCliResult._(null, error);
}

/// 随包 exe 所在目录：发布后 avifenc/dec.exe 与主程序同目录（CMake install）。
String get _bundledDir {
  final p = Platform.resolvedExecutable;
  return p.substring(0, p.lastIndexOf(Platform.pathSeparator));
}

String _resolveExe(String name, String? dir) {
  final base = dir ?? _bundledDir;
  return '$base${Platform.pathSeparator}$name';
}

Uint8List _pngBytes({
  required Uint8List rgba,
  required int width,
  required int height,
}) {
  final image = img.Image.fromBytes(
    width: width,
    height: height,
    bytes: rgba.buffer,
    numChannels: 4,
    order: img.ChannelOrder.rgba,
  );
  return img.encodePng(image);
}

/// 用 avifenc 把 RGBA 像素编码为 AVIF，PNG 经 stdin 管道送入。
///
/// [quality] 0–100（对应 avifenc -q，100 为无损）。
/// [exeDir] 供测试注入 exe 所在目录；null 时用随包目录。
Future<AvifCliResult> encodeAvifCli({
  required Uint8List rgba,
  required int width,
  required int height,
  required int quality,
  String? exeDir,
}) async {
  if (width <= 0 || height <= 0) {
    return AvifCliResult.fail('invalid size');
  }
  if (rgba.length < width * height * 4) {
    return AvifCliResult.fail('insufficient pixels');
  }
  final exe = _resolveExe('avifenc.exe', exeDir);
  if (!File(exe).existsSync()) {
    return AvifCliResult.fail('avifenc.exe not found');
  }

  final png = _pngBytes(rgba: rgba, width: width, height: height);
  final tmp = Directory.systemTemp.createTempSync('pf_avif_enc_');
  final out = '${tmp.path}${Platform.pathSeparator}out.avif';
  try {
    final process = await Process.start(exe, [
      '--stdin',
      '--input-format',
      'png',
      '-q',
      quality.clamp(0, 100).toString(),
      '-s',
      '10',
      '-o',
      out,
    ]);
    process.stdin.add(png);
    await process.stdin.close();
    final stderr = <int>[];
    final stderrDone = process.stderr.listen(stderr.addAll).asFuture<void>();
    await stderrDone;
    final exitCode = await process.exitCode;
    if (exitCode != 0 || !File(out).existsSync()) {
      return AvifCliResult.fail(String.fromCharCodes(stderr));
    }
    return AvifCliResult.ok(File(out).readAsBytesSync());
  } catch (e) {
    return AvifCliResult.fail(e.toString());
  } finally {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  }
}

/// 用 avifdec 把 AVIF 字节解码为 PNG。
///
/// [maxPixels] 经 avifdec --size-limit 传入，超限由 CLI 拒绝。
/// [exeDir] 供测试注入 exe 所在目录；null 时用随包目录。
Future<AvifCliResult> decodeAvifCli(
  Uint8List bytes, {
  required int maxPixels,
  String? exeDir,
}) async {
  final exe = _resolveExe('avifdec.exe', exeDir);
  if (!File(exe).existsSync()) {
    return AvifCliResult.fail('avifdec.exe not found');
  }

  final tmp = Directory.systemTemp.createTempSync('pf_avif_dec_');
  final input = '${tmp.path}${Platform.pathSeparator}in.avif';
  final out = '${tmp.path}${Platform.pathSeparator}out.png';
  try {
    File(input).writeAsBytesSync(bytes);
    final result = await Process.run(exe, [
      '--size-limit',
      maxPixels.toString(),
      input,
      out,
    ], stdoutEncoding: null, stderrEncoding: null);
    if (result.exitCode != 0 || !File(out).existsSync()) {
      return AvifCliResult.fail(result.stderr?.toString() ?? 'decode failed');
    }
    return AvifCliResult.ok(File(out).readAsBytesSync());
  } catch (e) {
    return AvifCliResult.fail(e.toString());
  } finally {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  }
}
