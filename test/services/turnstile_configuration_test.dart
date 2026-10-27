import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/network/cf/turnstile_configuration.dart';

void main() {
  final idc = Uri.parse('https://idcflare.com/');
  final linux = Uri.parse('https://linux.do/');
  const key = '0x4AAAAAAATestPublicKey';
  const other = '0x4AAAAAAADifferentKey';

  TurnstileConfiguration? html(String text, {Uri? source, Uri? expected}) =>
      TurnstileConfiguration.fromHtml(
        text,
        source: source ?? idc,
        expected: expected ?? idc,
      );

  group('只发现站点自己嵌入的公开配置', () {
    test('识别单引号、双引号、动态容器属性和公开 render 配置', () {
      for (final markup in [
        '<div class="cf-turnstile" data-sitekey="$key"></div>',
        "<div class='cf-turnstile' data-sitekey='$key'></div>",
        '<div id="site-turnstile" data-sitekey="$key"></div>',
        '''<script src="https://challenges.cloudflare.com/turnstile/v0/api.js"></script>
        <div data-sitekey="$key"></div>''',
        '''<script>turnstile.render('#widget', {sitekey: '$key'});</script>''',
        '''<script>window.turnstile.render('#widget', {"sitekey": "$key"});</script>''',
      ]) {
        expect(html(markup)?.sitekey, key, reason: markup);
        expect(html(markup)?.origin, idc.origin);
      }
    });

    test('Managed Challenge 的内部 widget key 不可复用于续期', () {
      expect(
        html('''<script>window._cf_chl_opt = {cType: 'managed'};
        turnstile.render('#managed', {sitekey: '$key'});</script>'''),
        isNull,
      );
    });

    test('普通第三方验证码、用户内容、预加载 JSON 与不明确配置不采纳', () {
      for (final markup in [
        '<div class="h-captcha" data-sitekey="$key"></div>',
        '<script src="https://["></script><div data-sitekey="$key"></div>',
        '''<script src="https://challenges.cloudflare.com.evil.test/turnstile/v0/api.js"></script>
        <div data-sitekey="$key"></div>''',
        '<article><div class="cf-turnstile" data-sitekey="$key"></div></article>',
        '<div class="cooked"><div class="cf-turnstile" data-sitekey="$key"></div></div>',
        '''<script type="application/json">{"sample": "turnstile.render", "sitekey": "$key"}</script>''',
        '''<script>hcaptcha.render('#widget', {sitekey: '$key'});</script>''',
        '<div class="cf-turnstile" data-sitekey="short"></div>',
        '<div class="cf-turnstile" data-sitekey="$key.invalid"></div>',
        '<div class="cf-turnstile" data-sitekey="${'x' * 101}"></div>',
      ]) {
        expect(html(markup), isNull, reason: markup);
      }
    });

    test('同一 key 重复无碍，存在多个不同 key 时不猜测', () {
      expect(
        html('<div class="cf-turnstile" data-sitekey="$key"></div>' * 2)
            ?.sitekey,
        key,
      );
      expect(
        html('''<div class="cf-turnstile" data-sitekey="$key"></div>
        <div class="cf-turnstile" data-sitekey="$other"></div>'''),
        isNull,
      );
    });

    test('两站来源隔离，不接受 http、非默认端口和伪造的同名域', () {
      final markup = '<div class="cf-turnstile" data-sitekey="$key"></div>';
      for (final source in [
        linux,
        Uri.parse('http://idcflare.com/'),
        Uri.parse('https://idcflare.com:8443/'),
        Uri.parse('https://idcflare.com.evil.test/'),
        Uri.parse('https://user@idcflare.com/'),
        Uri.parse('https:idcflare.com'),
      ]) {
        expect(html(markup, source: source), isNull, reason: '$source');
      }
      expect(
        html(markup, source: linux, expected: linux)?.origin,
        linux.origin,
      );
    });
  });

  group('主 frame 动态 DOM 快照', () {
    Map<String, Object> snapshot() => {
      'href': '$idc',
      'managed': false,
      'keys': [key],
    };
    TurnstileConfiguration? read(Object? value) =>
        TurnstileConfiguration.fromSnapshot(value, expected: idc);

    test('接受 Map 或 JSON，且返回的都是本站配置', () {
      expect(read(snapshot())?.sitekey, key);
      expect(read(jsonEncode(snapshot()))?.sitekey, key);
    });

    test('拒绝 managed、外国 frame、坏数据与多个 key', () {
      for (final value in <Object?>[
        null,
        'not-json',
        [],
        {},
        {...snapshot(), 'managed': true},
        {...snapshot(), 'managed': 'false'},
        {...snapshot(), 'href': 'https://challenges.cloudflare.com/'},
        {...snapshot(), 'href': '$linux'},
        {...snapshot(), 'href': 'https:idcflare.com'},
        {...snapshot(), 'keys': key},
        {
          ...snapshot(),
          'keys': ['bad'],
        },
        {
          ...snapshot(),
          'keys': [key, other],
        },
      ]) {
        expect(read(value), isNull, reason: '$value');
      }
    });
  });

  group('配置缓存', () {
    final now = DateTime.utc(2026, 10, 25, 12);
    final config = TurnstileConfiguration(origin: idc.origin, sitekey: key);
    TurnstileConfiguration? read(
      String? value, {
      Uri? origin,
      DateTime? clock,
    }) => TurnstileConfiguration.decode(
      value,
      expected: origin ?? idc,
      now: clock ?? now,
    );

    test('仅恢复同站点、未过期的公开配置', () {
      final encoded = config.encode(now.subtract(const Duration(hours: 2)));
      expect(read(encoded)?.sitekey, key);
      expect(read(encoded, origin: linux), isNull);
      expect(
        TurnstileConfiguration.cacheKey(idc),
        isNot(TurnstileConfiguration.cacheKey(linux)),
      );
      expect(
        jsonDecode(encoded).keys,
        unorderedEquals(['origin', 'sitekey', 'observedAt']),
      );
    });

    test('过期、未来时间与坏缓存不启动后台 WebView', () {
      expect(
        read(config.encode(now.subtract(TurnstileConfiguration.cacheLifetime))),
        isNull,
      );
      expect(read(config.encode(now.add(const Duration(minutes: 1)))), isNull);
      expect(read('[]'), isNull);
      expect(read('{bad json'), isNull);
      expect(read(null), isNull);
      expect(read(jsonEncode({'origin': '$idc', 'sitekey': key})), isNull);
    });
  });
}
