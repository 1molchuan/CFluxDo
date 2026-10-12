import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/network/doh/bootstrap_doh_client.dart';

/// 找到 HTTP 头部结束位置（\r\n\r\n 的起点）
int _headerEnd(Uint8List bytes) {
  for (var i = 0; i + 3 < bytes.length; i++) {
    if (bytes[i] == 0x0D &&
        bytes[i + 1] == 0x0A &&
        bytes[i + 2] == 0x0D &&
        bytes[i + 3] == 0x0A) {
      return i;
    }
  }
  return -1;
}

void main() {
  group('BootstrapDohClient 请求格式', () {
    late Uint8List query;

    setUp(() {
      query = BootstrapDohClient(serverUrl: 'https://example.invalid/dns-query')
          .buildDnsQuery('linux.do');
    });

    test('DNS 报文是标准 A 查询', () {
      // 12 字节头 + "linux.do" 的 QNAME（1+5+1+2+1）+ QTYPE + QCLASS
      expect(query.length, 12 + 10 + 4);
      expect(query[2], 0x01); // RD
      expect(query.sublist(4, 6), [0, 1]); // QDCOUNT
      expect(ascii.decode(query.sublist(13, 18)), 'linux');
      expect(query.sublist(query.length - 4), [0, 1, 0, 1]); // A, IN
    });

    test('默认 POST：报文放请求体，带固定 UA 和令牌，地址里没有 dns=', () {
      final client = BootstrapDohClient(
        serverUrl: 'https://abcdefghijkl.wq.1molchuan.top/v1/lookup',
        authToken: 'test-token',
      );
      final bytes = client.buildHttpRequest(query);
      final headEnd = _headerEnd(bytes);
      expect(headEnd, greaterThan(0));
      final lines = ascii.decode(bytes.sublist(0, headEnd)).split('\r\n');

      expect(lines.first, 'POST /v1/lookup HTTP/1.1');
      expect(lines, contains('Host: abcdefghijkl.wq.1molchuan.top'));
      expect(lines, contains('User-Agent: $dohUserAgent'));
      expect(lines, contains('Accept: application/dns-message'));
      expect(lines, contains('Content-Type: application/dns-message'));
      expect(lines, contains('Content-Length: ${query.length}'));
      expect(lines, contains('Authorization: Bearer test-token'));
      expect(lines, contains('Connection: keep-alive'));
      expect(lines.join(), isNot(contains('dns=')));
      expect(bytes.sublist(headEnd + 4), query);
      expect(client.usesGet, isFalse);
    });

    test('没有令牌时不带 Authorization', () {
      final client = BootstrapDohClient(
        serverUrl: 'https://edge.1molchuan.top/linuxdo',
      );
      final bytes = client.buildHttpRequest(query);
      final head = ascii.decode(bytes.sublist(0, _headerEnd(bytes)));
      expect(head, startsWith('POST /linuxdo HTTP/1.1\r\n'));
      expect(head.toLowerCase(), isNot(contains('authorization')));
    });

    test('服务器拒绝过 POST 后改用 GET ?dns=，不带请求体', () {
      final client = BootstrapDohClient(
        serverUrl: 'https://edge.1molchuan.top/linuxdo',
        authToken: 'test-token',
      )..useGetForTesting();
      final bytes = client.buildHttpRequest(query);
      final head = ascii.decode(bytes);
      final encoded = base64Url.encode(query).replaceAll('=', '');

      expect(client.usesGet, isTrue);
      expect(head, startsWith('GET /linuxdo?dns=$encoded HTTP/1.1\r\n'));
      expect(head, contains('User-Agent: $dohUserAgent\r\n'));
      expect(head, contains('Accept: application/dns-message\r\n'));
      expect(head, contains('Authorization: Bearer test-token\r\n'));
      expect(head, isNot(contains('Content-Type')));
      expect(head, isNot(contains('Content-Length')));
      expect(head, endsWith('\r\n\r\n'));
    });

    test('没写路径时默认 /dns-query', () {
      final client = BootstrapDohClient(serverUrl: 'https://dns.example');
      final bytes = client.buildHttpRequest(query);
      final head = ascii.decode(bytes.sublist(0, _headerEnd(bytes)));
      expect(head, startsWith('POST /dns-query HTTP/1.1\r\n'));
      expect(head, contains('Host: dns.example\r\n'));
    });
  });
}
