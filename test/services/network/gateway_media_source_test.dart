import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/network/gateway_media_source.dart';

void main() {
  GatewayMediaSource rewrite(String url, {bool gateway = true, int? port = 40527}) =>
      GatewayMediaSource.rewrite(Uri.parse(url), gatewayMode: gateway, port: port);

  test('网关模式下 https 媒体改写成本机网关 + Host 头，路径和查询原样保留', () {
    final source = rewrite(
      'https://cdn3.ldstatic.com/original/4X/a/b/%E4%B8%AD%E6%96%87.mp4?dl=1',
    );
    expect(
      source.uri.toString(),
      'http://127.0.0.1:40527/original/4X/a/b/%E4%B8%AD%E6%96%87.mp4?dl=1',
    );
    expect(source.headers, {'Host': 'cdn3.ldstatic.com'});
  });

  test('不在网关模式、没有端口时原样返回', () {
    const url = 'https://linux.do/uploads/default/original/1X/a.mp4';
    for (final source in [rewrite(url, gateway: false), rewrite(url, port: null)]) {
      expect(source.uri.toString(), url);
      expect(source.headers, isEmpty);
    }
  });

  test('http、非默认端口、带账号信息的地址不改写', () {
    for (final url in [
      'http://example.com/a.mp4',
      'https://example.com:8443/a.mp4',
      'https://user:pw@example.com/a.mp4',
      'file:///sdcard/a.mp4',
    ]) {
      final source = rewrite(url);
      expect(source.uri.toString(), url, reason: url);
      expect(source.headers, isEmpty, reason: url);
    }
  });
}
