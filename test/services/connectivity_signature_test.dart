import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/connectivity_service.dart';

void main() {
  group('ConnectivityService.signatureOf', () {
    test('单一连接类型直接用名字', () {
      expect(ConnectivityService.signatureOf([ConnectivityResult.wifi]), 'wifi');
      expect(
        ConnectivityService.signatureOf([ConnectivityResult.mobile]),
        'mobile',
      );
    });

    test('多个类型按名字排序后用 | 连接，与输入顺序无关', () {
      expect(
        ConnectivityService.signatureOf([
          ConnectivityResult.wifi,
          ConnectivityResult.vpn,
        ]),
        'vpn|wifi',
      );
      expect(
        ConnectivityService.signatureOf([
          ConnectivityResult.vpn,
          ConnectivityResult.wifi,
        ]),
        'vpn|wifi',
      );
      expect(
        ConnectivityService.signatureOf([
          ConnectivityResult.wifi,
          ConnectivityResult.mobile,
          ConnectivityResult.ethernet,
        ]),
        'ethernet|mobile|wifi',
      );
    });

    test('重复项去重', () {
      expect(
        ConnectivityService.signatureOf([
          ConnectivityResult.wifi,
          ConnectivityResult.wifi,
          ConnectivityResult.vpn,
          ConnectivityResult.wifi,
        ]),
        'vpn|wifi',
      );
    });

    test('none 被过滤掉', () {
      expect(
        ConnectivityService.signatureOf([
          ConnectivityResult.none,
          ConnectivityResult.wifi,
        ]),
        'wifi',
      );
      expect(ConnectivityService.signatureOf([ConnectivityResult.none]), '');
      expect(
        ConnectivityService.signatureOf([
          ConnectivityResult.none,
          ConnectivityResult.none,
        ]),
        '',
      );
    });

    test('空列表返回空串', () {
      expect(ConnectivityService.signatureOf(const []), '');
    });
  });

  group('ConnectivityService.seedInitialSignature', () {
    final signature = ConnectivityService().networkSignature;
    setUp(() => signature.value = null);
    tearDown(() => signature.value = null);

    test('起代理前种下签名', () {
      ConnectivityService().seedInitialSignature([
        ConnectivityResult.wifi,
        ConnectivityResult.vpn,
      ]);
      expect(signature.value, 'vpn|wifi');
    });

    test('超时（空列表）或瞬态 none 不种，保持未知', () {
      ConnectivityService().seedInitialSignature(const []);
      expect(signature.value, isNull);
      ConnectivityService().seedInitialSignature([ConnectivityResult.none]);
      expect(signature.value, isNull);
    });

    test('已有签名时不覆盖', () {
      signature.value = 'mobile';
      ConnectivityService().seedInitialSignature([ConnectivityResult.wifi]);
      expect(signature.value, 'mobile');
    });
  });
}
