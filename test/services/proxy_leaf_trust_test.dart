import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/network/doh_proxy/proxy_leaf_trust.dart';

void main() {
  group('ProxyLeafTrust.pemToDer', () {
    test('去掉 PEM 头尾与换行后按 base64 解码', () {
      final der = List<int>.generate(300, (i) => i % 256);
      final b64 = base64.encode(der);
      final lines = <String>[];
      for (var i = 0; i < b64.length; i += 64) {
        lines.add(b64.substring(i, i + 64 > b64.length ? b64.length : i + 64));
      }
      final pem =
          '-----BEGIN CERTIFICATE-----\r\n${lines.join('\r\n')}\r\n-----END CERTIFICATE-----\r\n';
      expect(ProxyLeafTrust.pemToDer(pem), der);
    });

    test('不是 base64 时返回 null', () {
      expect(
        ProxyLeafTrust.pemToDer(
          '-----BEGIN CERTIFICATE-----\n@@@\n-----END CERTIFICATE-----',
        ),
        isNull,
      );
    });
  });
}
