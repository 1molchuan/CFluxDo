import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/config/forum_site.dart';
import 'package:fluxdo/services/credential_store_service.dart';
import 'package:fluxdo/services/site_context.dart';
import 'package:fluxdo/services/user_api_key_service.dart';
import 'package:fluxdo/services/network/cookie/csrf_token_service.dart';
import 'package:fluxdo/services/webview_session_cookie_refresh_service.dart';
import 'package:pointycastle/export.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const secure = FlutterSecureStorage();
  late AsymmetricKeyPair<PublicKey, PrivateKey> linuxKeys;
  late AsymmetricKeyPair<PublicKey, PrivateKey> idcKeys;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({
      SiteContext.selectionKey: ForumSite.idcFlare.id,
    });
    await SiteContext.initialize(await SharedPreferences.getInstance());
    linuxKeys = _keyPair(1);
    idcKeys = _keyPair(2);
  });

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({
      'login_credential_username': 'same-user',
      'login_credential_password': 'linux-password',
      'user_api_key_key': 'linux-api-key',
      'user_api_key_pending_nonce': 'linux-nonce',
      'user_api_key_rsa_private': _privateJson(linuxKeys.privateKey as RSAPrivateKey),
      'site:idcflare:login_credential_username': 'same-user',
      'site:idcflare:login_credential_password': 'idc-password',
      'site:idcflare:user_api_key_key': 'idc-api-key',
      'site:idcflare:user_api_key_pending_nonce': 'idc-nonce',
      'site:idcflare:user_api_key_rsa_private': _privateJson(idcKeys.privateKey as RSAPrivateKey),
      'linux_do_csrf_token': 'linux-csrf',
      'site:idcflare:linux_do_csrf_token': 'idc-csrf',
      'ai_api_key_external': 'global-ai-secret',
    });
  });

  test('同名账号读取和清除只作用于本站，旧站及全局AI秘密保留', () async {
    final credentials = CredentialStoreService();
    expect(await credentials.load(), (username: 'same-user', password: 'idc-password'));
    await credentials.save('new-idc-user', 'new-idc-password');
    expect(await credentials.load(), (username: 'new-idc-user', password: 'new-idc-password'));
    expect(await secure.read(key: 'login_credential_password'), 'linux-password');
    await credentials.clear();
    expect(await credentials.hasCredentials(), isFalse);
    expect(await secure.read(key: 'login_credential_username'), 'same-user');
    expect(await secure.read(key: 'login_credential_password'), 'linux-password');
    expect(await secure.read(key: 'ai_api_key_external'), 'global-ai-secret');
  });

  test('APIKey读取和清除不触碰旧站APIKey', () async {
    final service = UserApiKeyService();
    expect(await service.readApiKey(), 'idc-api-key');
    await service.clearKey();
    expect(await service.hasKey(), isFalse);
    expect(await secure.read(key: 'user_api_key_key'), 'linux-api-key');
  });

  test('CSRF恢复与重置仅操作本站安全存储键', () async {
    final csrf = CsrfTokenService();
    await csrf.init();
    expect(csrf.csrfToken, 'idc-csrf');
    await csrf.reset();
    expect(await secure.read(key: 'site:idcflare:linux_do_csrf_token'), isNull);
    expect(await secure.read(key: 'linux_do_csrf_token'), 'linux-csrf');
  });

  test('IDCFlare不伪造LinuxDO专属fingerprint bootstrap成功', () async {
    final bootstrap = WebViewSessionCookieRefreshService.instance;
    expect(bootstrap.supportsBootstrap, isFalse);
    final result = await bootstrap.ensureSynced();
    expect(result.ok, isFalse);
    expect(result.phase, 'not_applicable');
  });

  test('加密回调只读识别各站目标，错误站点不会消费nonce或写凭据', () async {
    final service = UserApiKeyService();
    final linuxCallback = _callback(linuxKeys.publicKey as RSAPublicKey, 'linux-nonce', 'new-linux-key');
    expect(await service.resolveAuthRedirectSite(linuxCallback), ForumSite.linuxDo);
    expect(await secure.read(key: 'user_api_key_pending_nonce'), 'linux-nonce');
    final rejected = await service.handleAuthRedirect(linuxCallback);
    expect(rejected.stale, isTrue);
    expect(await service.readApiKey(), 'idc-api-key');
    expect(await secure.read(key: 'user_api_key_key'), 'linux-api-key');
    expect(await secure.read(key: 'user_api_key_pending_nonce'), 'linux-nonce');
  });

  test('本站回调校验nonce，错nonce保持pending，正确nonce一次性消费', () async {
    final service = UserApiKeyService();
    final wrong = _callback(idcKeys.publicKey as RSAPublicKey, 'linux-nonce', 'wrong-key');
    expect(await service.resolveAuthRedirectSite(wrong), isNull);
    expect((await service.handleAuthRedirect(wrong)).stale, isTrue);
    expect(await secure.read(key: 'site:idcflare:user_api_key_pending_nonce'), 'idc-nonce');
    expect(await service.readApiKey(), 'idc-api-key');

    final correct = _callback(idcKeys.publicKey as RSAPublicKey, 'idc-nonce', 'new-idc-key');
    expect(await service.resolveAuthRedirectSite(correct), ForumSite.idcFlare);
    expect((await service.handleAuthRedirect(correct)).ok, isTrue);
    expect(await service.readApiKey(), 'new-idc-key');
    expect(await secure.read(key: 'site:idcflare:user_api_key_pending_nonce'), isNull);
    expect(await service.resolveAuthRedirectSite(correct), isNull);
    expect((await service.handleAuthRedirect(correct)).stale, isTrue);
    expect(await secure.read(key: 'user_api_key_key'), 'linux-api-key');
    expect(await secure.read(key: 'user_api_key_pending_nonce'), 'linux-nonce');
  });
}

AsymmetricKeyPair<PublicKey, PrivateKey> _keyPair(int seed) {
  final random = FortunaRandom()
    ..seed(KeyParameter(Uint8List.fromList(List.generate(32, (i) => i + seed))));
  final generator = RSAKeyGenerator()
    ..init(ParametersWithRandom(
      RSAKeyGeneratorParameters(BigInt.from(65537), 1024, 64),
      random,
    ));
  return generator.generateKeyPair();
}

String _privateJson(RSAPrivateKey key) => jsonEncode({
  'n': key.modulus!.toRadixString(16),
  'd': key.privateExponent!.toRadixString(16),
  'p': key.p!.toRadixString(16),
  'q': key.q!.toRadixString(16),
});

Uri _callback(RSAPublicKey publicKey, String nonce, String apiKey) {
  final cipher = PKCS1Encoding(RSAEngine())
    ..init(true, PublicKeyParameter<RSAPublicKey>(publicKey));
  final payload = cipher.process(Uint8List.fromList(utf8.encode(jsonEncode({
    'nonce': nonce,
    'key': apiKey,
  }))));
  return Uri.parse('discourse://auth_redirect').replace(queryParameters: {
    'payload': base64Encode(payload),
  });
}
