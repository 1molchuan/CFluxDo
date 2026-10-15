import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/update_service.dart';

void main() {
  ApkAsset asset(String name) => ApkAsset(
    downloadUrl: 'https://example.invalid/$name',
    architecture: UpdateService.abiOfFileName(name)!,
    size: 1,
    name: name,
  );

  group('发行包 ABI 挑选', () {
    test('按设备声明的顺序取第一个有包的 ABI', () {
      expect(
        UpdateService.pickReleaseAbi(['arm64-v8a', 'armeabi-v7a', 'armeabi']),
        'arm64-v8a',
      );
      expect(
        UpdateService.pickReleaseAbi(['armeabi-v7a', 'armeabi']),
        'armeabi-v7a',
      );
      expect(UpdateService.pickReleaseAbi(['x86_64', 'x86']), isNull);
      expect(UpdateService.pickReleaseAbi([]), isNull);
    });

    test('从文件名识别 ABI，别的文件忽略', () {
      expect(
        UpdateService.abiOfFileName('cfluxdo-1.1.0-arm64-v8a.apk'),
        'arm64-v8a',
      );
      expect(
        UpdateService.abiOfFileName('cfluxdo-1.1.0-armeabi-v7a.apk'),
        'armeabi-v7a',
      );
      expect(UpdateService.abiOfFileName('cfluxdo-1.1.0-x86_64.apk'), isNull);
      expect(
        UpdateService.abiOfFileName('cfluxdo-1.1.0-arm64-v8a.apk.sha256'),
        isNull,
      );
    });

    test('64 位机优先 arm64 包，Release 里没有时退到 v7a 包', () {
      final both = [
        asset('cfluxdo-1.1.0-armeabi-v7a.apk'),
        asset('cfluxdo-1.1.0-arm64-v8a.apk'),
      ];
      expect(
        UpdateService.pickApkAsset(['arm64-v8a', 'armeabi-v7a'], both)?.name,
        'cfluxdo-1.1.0-arm64-v8a.apk',
      );
      final onlyV7 = [asset('cfluxdo-1.1.0-armeabi-v7a.apk')];
      expect(
        UpdateService.pickApkAsset(['arm64-v8a', 'armeabi-v7a'], onlyV7)?.name,
        'cfluxdo-1.1.0-armeabi-v7a.apk',
      );
      // 纯 32 位机绝不能拿到 arm64 包
      expect(
        UpdateService.pickApkAsset(['armeabi-v7a', 'armeabi'], [
          asset('cfluxdo-1.1.0-arm64-v8a.apk'),
        ]),
        isNull,
      );
    });
  });
}
