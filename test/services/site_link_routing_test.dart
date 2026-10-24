import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/config/forum_site.dart';
import 'package:fluxdo/pages/search_page.dart';
import 'package:fluxdo/utils/link_launcher.dart';
import 'package:fluxdo/utils/url_helper.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    UrlHelper.debugSetOverrides(baseUri: '/');
  });
  tearDown(UrlHelper.debugClearOverrides);

  test('原生论坛路由只接受当前站主域和合法 HTTP 地址', () {
    expect(isInternalUrlString('/t/123'), isTrue);
    expect(isInternalUrlString('//linux.do/t/123'), isTrue);
    expect(isInternalUrlString('https://linux.do:443/t/123'), isTrue);
    expect(isInternalUrlString('http://linux.do:80/t/123'), isTrue);
    for (final url in [
      '//idcflare.com/t/123',
      'https://idcflare.com/t/123',
      'https://cdn.linux.do/t/123',
      'https://linux.do.evil.test/t/123',
      'https://evillinux.do/t/123',
      'https://linux.do:80/t/123',
      'http://linux.do:443/t/123',
      'https://linux.do:8443/t/123',
      'https://user@linux.do/t/123',
      'ftp://linux.do/t/123',
    ]) {
      expect(isInternalUrlString(url), isFalse, reason: url);
    }
  });

  test('跨站目标拒绝协议端口错配和带凭据地址', () {
    expect(
      ForumSite.fromUri(Uri.parse('https://idcflare.com:443/t/1')),
      ForumSite.idcFlare,
    );
    expect(
      ForumSite.fromUri(Uri.parse('http://idcflare.com:80/t/1')),
      ForumSite.idcFlare,
    );
    for (final url in [
      'https://idcflare.com:80/t/1',
      'http://idcflare.com:443/t/1',
      'https://user@idcflare.com/t/1',
      'https://idcflare.com.evil.test/t/1',
    ]) {
      expect(ForumSite.fromUri(Uri.parse(url)), isNull, reason: url);
    }
  });

  test('搜索直达支持两站裸域名且不修正伪域和关键词', () {
    expect(
      normalizeDirectSearchLink(' linux.do/t/123 '),
      'https://linux.do/t/123',
    );
    expect(
      normalizeDirectSearchLink('idcflare.com/t/123'),
      'https://idcflare.com/t/123',
    );
    expect(
      normalizeDirectSearchLink('//idcflare.com/t/123'),
      '//idcflare.com/t/123',
    );
    expect(
      isInternalUrlString(normalizeDirectSearchLink('//idcflare.com/t/123')),
      isFalse,
    );
    for (final value in [
      'idcflare.com.evil.test/t/123',
      'evillinux.do/t/123',
      '普通关键词',
    ]) {
      expect(normalizeDirectSearchLink(value), value);
    }
  });
}
