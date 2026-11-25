import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_format_factory/core/platform/app_platform.dart';
import 'package:image_format_factory/services/image/webp_encoder.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(WebpEncoder.channelName);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  final rgba = Uint8List.fromList([255, 0, 0, 255, 0, 255, 0, 255]);
  final encoded = Uint8List.fromList([0x52, 0x49, 0x46, 0x46]);

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('Android 端走平台通道，参数带全', () async {
    MethodCall? received;
    messenger.setMockMethodCallHandler(channel, (call) async {
      received = call;
      return encoded;
    });

    final r = await WebpEncoder.encode(
      rgba: rgba,
      width: 2,
      height: 1,
      quality: 88,
      target: AppTarget.android,
    );

    expect(r.isSuccess, isTrue);
    expect(r.bytes, encoded);
    expect(received?.method, 'encode');
    expect(received?.arguments['width'], 2);
    expect(received?.arguments['height'], 1);
    expect(received?.arguments['quality'], 88);
    expect(received?.arguments['rgba'], rgba);
  });

  test('平台报不支持 → unsupportedPlatform', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(code: 'unsupported');
    });

    final r = await WebpEncoder.encode(
      rgba: rgba,
      width: 2,
      height: 1,
      quality: 88,
      target: AppTarget.android,
    );

    expect(r.error, WebpEncodeError.unsupportedPlatform);
  });

  test('通道未注册 → unsupportedPlatform', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      throw MissingPluginException('未实现');
    });

    final r = await WebpEncoder.encode(
      rgba: rgba,
      width: 2,
      height: 1,
      quality: 88,
      target: AppTarget.android,
    );

    expect(r.error, WebpEncodeError.unsupportedPlatform);
  });

  test('其余端直接判不支持，不触碰通道', () async {
    var called = false;
    messenger.setMockMethodCallHandler(channel, (call) async {
      called = true;
      return encoded;
    });

    for (final target in [
      AppTarget.harmony,
      AppTarget.wechatMini,
    ]) {
      final r = await WebpEncoder.encode(
        rgba: rgba,
        width: 2,
        height: 1,
        quality: 88,
        target: target,
      );
      expect(r.isSuccess, isFalse, reason: target.displayName);
      expect(r.error, WebpEncodeError.unsupportedPlatform);
    }
    expect(called, isFalse, reason: '不支持时不应发起平台调用');
  });

  test('Windows 端缺少 libwebp 时如实报不可用', () async {
    final r = await WebpEncoder.encode(
      rgba: rgba,
      width: 2,
      height: 1,
      quality: 88,
      target: AppTarget.windows,
      libraryPath: '不存在的路径/webp.dll',
    );

    expect(r.isSuccess, isFalse);
    expect(r.error, WebpEncodeError.nativeUnavailable);
  });
}
