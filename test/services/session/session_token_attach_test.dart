import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/discourse/discourse_service.dart';
import 'package:fluxdo/services/session/session_token_authority.dart';

import 'session_token_fakes.dart';

/// `_t` 认证接线的契约：显式接入，不靠 DiscourseService 构造的副作用。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('显式接线后 authority 立即有探测可用，不需要先构造 DiscourseService', () {
    final authority = SessionTokenAuthority(
      jar: FakeJarStore(),
      webView: FakeWebViewStore(),
      clock: FakeClock().call,
    );
    expect(authority.hasProbe, isFalse, reason: '前提：没接线时没有探测');

    DiscourseService.attachSessionTokenAuthority(authority: authority);

    expect(authority.hasProbe, isTrue);
  });
}
