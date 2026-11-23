import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/network/system_proxy_detector.dart';

void main() {
  group('SystemProxyDetector.parseProxyServer', () {
    test('host:port 形式默认 http', () {
      expect(
        SystemProxyDetector.parseProxyServer('127.0.0.1:7890'),
        'http://127.0.0.1:7890',
      );
    });

    test('带 scheme 的值归一化', () {
      expect(
        SystemProxyDetector.parseProxyServer('http://127.0.0.1:7890'),
        'http://127.0.0.1:7890',
      );
      expect(
        SystemProxyDetector.parseProxyServer('socks5://127.0.0.1:7891'),
        'socks5://127.0.0.1:7891',
      );
    });

    test('分协议列表优先 https,其次 http,最后 socks', () {
      expect(
        SystemProxyDetector.parseProxyServer(
          'http=1.2.3.4:80;https=1.2.3.4:443;socks=1.2.3.4:1080',
        ),
        'http://1.2.3.4:443',
      );
      expect(
        SystemProxyDetector.parseProxyServer('http=1.2.3.4:80;socks=1.2.3.4:1080'),
        'http://1.2.3.4:80',
      );
      expect(
        SystemProxyDetector.parseProxyServer('socks=1.2.3.4:1080'),
        'socks5://1.2.3.4:1080',
      );
    });

    test('非法输入返回 null', () {
      expect(SystemProxyDetector.parseProxyServer(''), isNull);
      expect(SystemProxyDetector.parseProxyServer('nonsense'), isNull);
      expect(SystemProxyDetector.parseProxyServer('ftp=1.2.3.4:21'), isNull);
      expect(SystemProxyDetector.parseProxyServer('host-without-port'), isNull);
    });
  });

  group('SystemProxyConfig', () {
    test('isEnabled 判定', () {
      expect(const SystemProxyConfig().isEnabled, isFalse);
      expect(
        const SystemProxyConfig(proxyUrl: 'http://127.0.0.1:7890').isEnabled,
        isTrue,
      );
      expect(
        const SystemProxyConfig(pacUrl: 'http://pac.local/p.pac').isEnabled,
        isTrue,
      );
    });
  });

  group('安卓 getDefaultProxy 读数', () {
    test('固定代理 → http://host:port', () {
      final c = SystemProxyDetector.parseAndroid({
        'host': '127.0.0.1',
        'port': 7890,
        'pac': null,
        'exclusions': <String>[],
      }, forumHost: 'linux.do');
      expect(c.proxyUrl, 'http://127.0.0.1:7890');
      expect(c.isEnabled, isTrue);
    });

    test('IPv6 主机加方括号', () {
      final c = SystemProxyDetector.parseAndroid({
        'host': 'fd00::1',
        'port': 8080,
      }, forumHost: 'linux.do');
      expect(c.proxyUrl, 'http://[fd00::1]:8080');
    });

    test('PAC：只记已启用，不给固定地址', () {
      final c = SystemProxyDetector.parseAndroid({
        'host': 'localhost',
        'port': -1,
        'pac': 'http://10.0.0.1/proxy.pac',
      }, forumHost: 'linux.do');
      expect(c.proxyUrl, isNull);
      expect(c.pacUrl, 'http://10.0.0.1/proxy.pac');
      expect(c.isEnabled, isTrue);
    });

    test('没有代理 / 端口不对 → 未启用', () {
      expect(
        SystemProxyDetector.parseAndroid(const {}, forumHost: 'linux.do')
            .isEnabled,
        isFalse,
      );
      expect(
        SystemProxyDetector.parseAndroid(null, forumHost: 'linux.do').isEnabled,
        isFalse,
      );
      expect(
        SystemProxyDetector.parseAndroid({
          'host': '10.0.0.2',
          'port': 0,
        }, forumHost: 'linux.do').isEnabled,
        isFalse,
      );
    });

    test('排除名单命中论坛 → 对论坛等于没有代理', () {
      for (final rule in ['linux.do', '*.linux.do', '*linux.do', '.linux.do', '*']) {
        final c = SystemProxyDetector.parseAndroid({
          'host': '10.0.0.2',
          'port': 3128,
          'exclusions': [rule],
        }, forumHost: 'linux.do');
        expect(c.isEnabled, isFalse, reason: rule);
      }
      final other = SystemProxyDetector.parseAndroid({
        'host': '10.0.0.2',
        'port': 3128,
        'exclusions': ['*.example.com', 'notlinux.do'],
      }, forumHost: 'linux.do');
      expect(other.proxyUrl, 'http://10.0.0.2:3128');
    });
  });
}
