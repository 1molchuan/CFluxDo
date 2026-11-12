import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/network/doh/custom_node_input.dart';
import 'package:fluxdo/services/network/doh/network_settings_service.dart';

/// 自定义节点的输入整理：写法校验与规范化（在不在 Cloudflare 网段由 Rust 引擎判断）
void main() {
  group('CustomNodeInput.normalize', () {
    test('IPv4：原样，带 :443 的去掉端口', () {
      expect(CustomNodeInput.normalize(' 104.18.0.9 '), '104.18.0.9');
      expect(CustomNodeInput.normalize('104.18.0.9:443'), '104.18.0.9');
    });

    test('IPv6：去方括号、统一成压缩写法', () {
      expect(CustomNodeInput.normalize('2606:4700::1'), '2606:4700::1');
      expect(CustomNodeInput.normalize('[2606:4700::1]'), '2606:4700::1');
      expect(CustomNodeInput.normalize('[2606:4700::1]:443'), '2606:4700::1');
      expect(
        CustomNodeInput.normalize('2606:4700:0:0:0:0:0:00A1'),
        '2606:4700::a1',
      );
      // 以 :443 结尾的合法 IPv6 不能被当成端口砍掉
      expect(CustomNodeInput.normalize('2606:4700::443'), '2606:4700::443');
      expect(CustomNodeInput.normalize('::1'), '::1');
      expect(
        CustomNodeInput.normalize('2606:4700:1:2:3:4:5:6'),
        '2606:4700:1:2:3:4:5:6',
      );
    });

    test('域名：小写、去末尾的点，网址只取主机', () {
      expect(CustomNodeInput.normalize('CF.Example.com.'), 'cf.example.com');
      expect(CustomNodeInput.normalize('cf.example.com:443'), 'cf.example.com');
      expect(
        CustomNodeInput.normalize('https://cf.example.com/path?x=1'),
        'cf.example.com',
      );
      expect(CustomNodeInput.normalize('https://104.18.0.9/'), '104.18.0.9');
      expect(
        CustomNodeInput.normalize('https://[2606:4700::1]/'),
        '2606:4700::1',
      );
    });

    test('写法不对的一律不收', () {
      for (final bad in [
        '',
        '   ',
        '1.2.3', // 写坏的 IP
        '300.1.1.1',
        '1.2.3.4.5',
        '104.18.0.9:8443', // 网关只连 443
        'https://cf.example.com:8443/',
        '[2606:4700::1]:8443',
        '[104.18.0.9]',
        'localhost',
        '-bad.example.com',
        'bad-.example.com',
        'exa mple.com',
        'fe80::1%eth0',
        '2606:4700::zz',
      ]) {
        expect(CustomNodeInput.normalize(bad), isNull, reason: bad);
      }
    });
  });

  group('CustomNodeInput.parse', () {
    test('换行、逗号、空白、中文标点都能分隔；重复的只留一个', () {
      final result = CustomNodeInput.parse(
        '104.18.0.9\n172.67.0.9, cf.example.com；[2606:4700::1]:443、'
        '104.18.0.9:443  2606:4700:0::1',
      );
      expect(result.nodes, [
        '104.18.0.9',
        '172.67.0.9',
        'cf.example.com',
        '2606:4700::1',
      ]);
      expect(result.invalid, isEmpty);
    });

    test('写错的单独列出来，不影响其余', () {
      final result = CustomNodeInput.parse('104.18.0.9, 1.2.3 ,foo\n1.2.3');
      expect(result.nodes, ['104.18.0.9']);
      expect(result.invalid, ['1.2.3', 'foo']);
    });

    test('空输入', () {
      final result = CustomNodeInput.parse('  \n ');
      expect(result.nodes, isEmpty);
      expect(result.invalid, isEmpty);
    });
  });

  group('CustomNodeInput.sanitize', () {
    test('去掉写错的和重复的，截到上限', () {
      expect(
        CustomNodeInput.sanitize([
          '104.18.0.9',
          'bogus',
          '104.18.0.9:443',
          'CF.example.com',
        ]),
        ['104.18.0.9', 'cf.example.com'],
      );
      final many = [for (var i = 1; i <= 20; i++) '104.18.0.$i'];
      expect(
        CustomNodeInput.sanitize(many),
        many.take(CustomNodeInput.maxEntries).toList(),
      );
    });
  });

  test('NetworkSettings 带着自定义节点清单', () {
    const base = NetworkSettings(
      dohEnabled: true,
      selectedServerUrl: 'https://edge.example/dns-query',
      customServers: [],
      proxyPort: 0,
    );
    expect(base.customNodes, isEmpty);
    final withNodes = base.copyWith(customNodes: ['104.18.0.9']);
    expect(withNodes.customNodes, ['104.18.0.9']);
    // 改别的设置不丢清单
    expect(withNodes.copyWith(dohEnabled: false).customNodes, ['104.18.0.9']);
  });
}
