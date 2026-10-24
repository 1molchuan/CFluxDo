import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/config/forum_site.dart';
import 'package:fluxdo/services/credential_store_service.dart';
import 'package:fluxdo/services/site_context.dart';
import 'package:fluxdo/services/user_api_key_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const secure = FlutterSecureStorage();

  test('重建引擎回到旧站沿用原凭据和APIKey，切换选择不改变在途写入归属', () async {
    SharedPreferences.setMockInitialValues({
      SiteContext.selectionKey: ForumSite.linuxDo.id,
    });
    FlutterSecureStorage.setMockInitialValues({
      'login_credential_username': 'same-user',
      'login_credential_password': 'linux-password',
      'user_api_key_key': 'linux-api-key',
      'site:idcflare:login_credential_username': 'same-user',
      'site:idcflare:login_credential_password': 'idc-password',
      'site:idcflare:user_api_key_key': 'idc-api-key',
    });
    final prefs = await SharedPreferences.getInstance();
    await SiteContext.initialize(prefs);
    final credentials = CredentialStoreService();
    final apiKeys = UserApiKeyService();
    expect(await credentials.load(), (username: 'same-user', password: 'linux-password'));
    expect(await apiKeys.readApiKey(), 'linux-api-key');

    await SiteContext.persistSelection(ForumSite.idcFlare);
    expect(SiteContext.current, ForumSite.linuxDo);
    await credentials.save('linux-updated', 'linux-password-updated');
    expect(await secure.read(key: 'login_credential_username'), 'linux-updated');
    expect(await secure.read(key: 'site:idcflare:login_credential_password'), 'idc-password');
    await apiKeys.clearKey();
    expect(await secure.read(key: 'user_api_key_key'), isNull);
    expect(await secure.read(key: 'site:idcflare:user_api_key_key'), 'idc-api-key');
  });
}
