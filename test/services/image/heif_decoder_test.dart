import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixel_forge/core/platform/app_platform.dart';
import 'package:pixel_forge/services/image/heif_decoder.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(HeifDecoder.channelName);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  final heicBytes = Uint8List.fromList([0, 0, 0, 24, ...'ftyp'.codeUnits]);
  final pngBytes = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 0x0D]);

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('非 Android/Windows 端直接判不支持，不触碰通道', () async {
    var called = false;
    messenger.setMockMethodCallHandler(channel, (call) async {
      called = true;
      return null;
    });

    for (final target in [
      AppTarget.harmony,
      AppTarget.web,
      AppTarget.wechatMini,
    ]) {
      final r = await HeifDecoder.decode(
        heicBytes,
        maxPixels: 32000000,
        target: target,
      );
      expect(r.isSuccess, isFalse, reason: target.displayName);
      expect(r.error, HeifDecodeError.unsupportedPlatform);
    }
    expect(called, isFalse, reason: '不支持时不应发起平台调用');
  });

  test('Windows 端走 libheif，不走平台通道', () async {
    var called = false;
    messenger.setMockMethodCallHandler(channel, (call) async {
      called = true;
      return pngBytes;
    });

    final r = await HeifDecoder.decode(
      heicBytes,
      maxPixels: 32000000,
      target: AppTarget.windows,
    );

    expect(called, isFalse, reason: 'Windows 走 FFI，不应发起平台调用');
    // 测试进程旁没有随包分发的 heif.dll，解码必然失败而不是报「不支持」
    expect(r.isSuccess, isFalse);
    expect(r.error, HeifDecodeError.failed);
  });

  test('Android 端透传平台解码结果，并带上像素上限', () async {
    MethodCall? received;
    messenger.setMockMethodCallHandler(channel, (call) async {
      received = call;
      return pngBytes;
    });

    final r = await HeifDecoder.decode(
      heicBytes,
      maxPixels: 32000000,
      target: AppTarget.android,
    );

    expect(r.png, pngBytes);
    expect(received?.method, 'decode');
    expect(received?.arguments['maxPixels'], 32000000);
    expect(received?.arguments['bytes'], heicBytes);
  });

  test('平台报像素超限 → pixelLimit', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(code: 'pixel-limit', message: '40000000');
    });

    final r = await HeifDecoder.decode(
      heicBytes,
      maxPixels: 32000000,
      target: AppTarget.android,
    );

    expect(r.error, HeifDecodeError.pixelLimit);
  });

  test('平台报不支持（系统版本过低）→ unsupportedPlatform', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(code: 'unsupported');
    });

    final r = await HeifDecoder.decode(
      heicBytes,
      maxPixels: 32000000,
      target: AppTarget.android,
    );

    expect(r.error, HeifDecodeError.unsupportedPlatform);
  });

  test('平台解码失败 → failed', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(code: 'decode-failed', message: '解码失败');
    });

    final r = await HeifDecoder.decode(
      heicBytes,
      maxPixels: 32000000,
      target: AppTarget.android,
    );

    expect(r.error, HeifDecodeError.failed);
  });

  test('通道未注册（旧包/未接入端）→ unsupportedPlatform', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      throw MissingPluginException('未实现');
    });

    final r = await HeifDecoder.decode(
      heicBytes,
      maxPixels: 32000000,
      target: AppTarget.android,
    );

    expect(r.error, HeifDecodeError.unsupportedPlatform);
  });
}
