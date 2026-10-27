import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/config/forum_site.dart';
import 'package:fluxdo/config/sites/idcflare.dart';
import 'package:fluxdo/services/cf_clearance_refresh_service.dart';
import 'package:fluxdo/services/network/cf/turnstile_configuration.dart';
import 'package:fluxdo/services/site_context.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final idc = Uri.parse(ForumSite.idcFlare.baseUrl);
  final linux = Uri.parse(ForumSite.linuxDo.baseUrl);
  const key = '0x4AAAAAAATestPublicKey';
  final service = CfClearanceRefreshService();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({
      SiteContext.selectionKey: 'idcflare',
    });
    await SiteContext.initialize(await SharedPreferences.getInstance());
  });
  setUp(() {
    service.debugResetConfiguration();
  });
  tearDown(() async {
    await service.stop();
  });

  test('保留 linux.do 专属 fingerprint 的能力边界并补齐 IDC 子域信任', () {
    expect(ForumSite.idcFlare.supportsFingerprintBootstrap, isFalse);
    expect(ForumSite.linuxDo.supportsFingerprintBootstrap, isTrue);
    expect(
      idcflareCustomization.linkSecurityConfig!.trustedDomains,
      contains('*.idcflare.com'),
    );
  });

  test('IDC 不会采用来自 linux.do / 验证框内部域名的配置', () {
    const markup = '<div class="cf-turnstile" data-sitekey="$key"></div>';
    service.extractAndUpdateSitekey(markup, source: linux);
    expect(service.sitekey, isNull);
    service.observeConfigurationSnapshot({
      'href': 'https://challenges.cloudflare.com/',
      'managed': false,
      'keys': [key],
    });
    expect(service.sitekey, isNull);
    service.extractAndUpdateSitekey(markup, source: idc);
    expect(service.sitekey, key);
  });

  test('HTML 和 DOM 连续发现同一配置时，缓存写入不会被后一次观察取消', () async {
    final prefs = await SharedPreferences.getInstance();
    final cacheKey = TurnstileConfiguration.cacheKey(idc);
    await prefs.remove(cacheKey);
    service.extractAndUpdateSitekey(
      '<div class="cf-turnstile" data-sitekey="$key"></div>',
      source: idc,
    );
    service.observeConfigurationSnapshot({
      'href': '$idc', 'managed': false, 'keys': [key],
    });
    // 等 SharedPreferences 写入，不启动 WebView。
    for (var i = 0; i < 10 && prefs.getString(cacheKey) == null; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    final restored = TurnstileConfiguration.decode(
      prefs.getString(cacheKey), expected: idc, now: DateTime.now(),
    );
    expect(restored?.sitekey, key);
  });

  test('恢复只取本站缓存，不启用 linux.do 已缓存的配置', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(TurnstileConfiguration.cacheKey(idc));
    await prefs.setString(
      TurnstileConfiguration.cacheKey(linux),
      TurnstileConfiguration(
        origin: linux.origin,
        sitekey: key,
      ).encode(DateTime.now()),
    );
    await service.ensureConfigurationLoaded();
    expect(service.sitekey, isNull);
    await prefs.setString(
      TurnstileConfiguration.cacheKey(idc),
      TurnstileConfiguration(
        origin: idc.origin,
        sitekey: key,
      ).encode(DateTime.now()),
    );
    service.debugResetConfiguration();
    await service.ensureConfigurationLoaded();
    expect(service.sitekey, key);
  });
}
