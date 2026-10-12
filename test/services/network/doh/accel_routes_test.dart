import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/network/doh/accel_doh_nodes.dart';
import 'package:fluxdo/services/network/doh/network_settings_service.dart';

void main() {
  group('accelRoutesUrlFor', () {
    test('本机专属加速 → 同 host 的 /v1/routes', () {
      final server = buildAccelDohServer('abcdefghijkl');
      expect(
        accelRoutesUrlFor(server.url),
        'https://abcdefghijkl.wq.1molchuan.top/v1/routes',
      );
    });

    test('公共加速 → edge 的 /v1/routes', () {
      expect(
        accelRoutesUrlFor(accelDohPublicServer.url),
        'https://edge.1molchuan.top/v1/routes',
      );
    });

    test('第三方 DoH 不查表', () {
      for (final url in [
        'https://doh.pub/dns-query',
        'https://dns.alidns.com/dns-query',
        'https://cloudflare-dns.com/dns-query',
        'https://wq.1molchuan.top.evil.example/v1/lookup',
        'http://edge.1molchuan.top/linuxdo',
        '',
        'not a url',
      ]) {
        expect(accelRoutesUrlFor(url), isNull, reason: url);
      }
    });

    test('isAccelDohHost 只认加速域名', () {
      expect(isAccelDohHost('edge.1molchuan.top'), isTrue);
      expect(isAccelDohHost('abcdefghijkl.wq.1molchuan.top'), isTrue);
      expect(isAccelDohHost('EDGE.1molchuan.top'), isTrue);
      expect(isAccelDohHost('1molchuan.top'), isFalse);
      expect(isAccelDohHost('doh.pub'), isFalse);
      expect(isAccelDohHost(''), isFalse);
    });
  });

  group('AccelNodeStore', () {
    const payload = {
      'serial': 7,
      'not_after': 4102444800, // 2100-01-01
      'hosts': {
        'wq.1molchuan.top': {
          'v4': ['198.51.100.1', '198.51.100.2'],
          'v6': ['2001:db8::1'],
        },
        'edge.1molchuan.top': {
          'v4': ['198.51.100.9'],
          'v6': <String>[],
        },
        'bad': {
          'v4': ['not-an-ip'],
        },
      },
    };

    test('从 payload 载入并按后缀匹配', () {
      final store = AccelNodeStore();
      expect(store.loadPayloadJson(jsonEncode(payload)), isTrue);
      expect(store.serial, 7);
      expect(store.ipsFor('abcdefghijkl.wq.1molchuan.top'), [
        '198.51.100.1',
        '198.51.100.2',
        '2001:db8::1',
      ]);
      expect(store.ipsFor('wq.1molchuan.top'), hasLength(3));
      expect(store.ipsFor('edge.1molchuan.top'), ['198.51.100.9']);
      expect(store.ipsFor('EDGE.1molchuan.top'), ['198.51.100.9']);
      // 非法 IP 的条目被丢掉
      expect(store.ipsFor('bad'), isEmpty);
      expect(store.ipsFor('x.bad'), isEmpty);
      // 不是后缀关系的不匹配
      expect(store.ipsFor('1molchuan.top'), isEmpty);
      expect(store.ipsFor('wq.1molchuan.top.example'), isEmpty);
    });

    test('最长 key 优先', () {
      final store = AccelNodeStore();
      store.loadPayloadJson(jsonEncode({
        'hosts': {
          '1molchuan.top': {'v4': ['198.51.100.1']},
          'wq.1molchuan.top': {'v4': ['198.51.100.2']},
        },
      }));
      expect(store.ipsFor('a.wq.1molchuan.top'), ['198.51.100.2']);
      expect(store.ipsFor('edge.1molchuan.top'), ['198.51.100.1']);
    });

    test('从信封里解出 payload', () {
      final store = AccelNodeStore();
      final envelope = jsonEncode({
        'kid': '2026-10',
        'payload': base64.encode(utf8.encode(jsonEncode(payload))),
        'sig': 'AAAA',
      });
      expect(store.loadEnvelopeJson(envelope), isTrue);
      expect(store.ipsFor('edge.1molchuan.top'), ['198.51.100.9']);
    });

    test('过期、格式错误、空内容都不覆盖已有节点', () {
      final store = AccelNodeStore();
      expect(store.loadPayloadJson(jsonEncode(payload)), isTrue);

      final expired = Map<String, Object?>.from(payload)..['not_after'] = 1;
      expect(store.loadPayloadJson(jsonEncode(expired)), isFalse);
      expect(store.loadPayloadJson('{not json'), isFalse);
      expect(store.loadPayloadJson(''), isFalse);
      expect(store.loadPayloadJson(null), isFalse);
      expect(store.loadPayloadJson(jsonEncode({'hosts': {}})), isFalse);
      expect(store.loadEnvelopeJson(jsonEncode({'payload': '%%%'})), isFalse);
      expect(store.loadEnvelopeJson(jsonEncode({'kid': 'x'})), isFalse);

      expect(store.serial, 7);
      expect(store.ipsFor('edge.1molchuan.top'), ['198.51.100.9']);
    });
  });

  group('mergeAccelBootstrapIps', () {
    test('已下发在前、种子在后，去重并保持顺序', () {
      expect(
        mergeAccelBootstrapIps(
          ['198.51.100.2', '156.239.232.8', '198.51.100.2'],
          accelDohBootstrapIps,
        ),
        [
          '198.51.100.2',
          '156.239.232.8',
          '156.239.232.72',
          '203.168.131.145',
          '103.199.103.204',
        ],
      );
    });

    test('没有下发时只剩种子', () {
      expect(mergeAccelBootstrapIps(const [], accelDohBootstrapIps),
          accelDohBootstrapIps);
    });
  });
}
