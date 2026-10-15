import 'package:enhanced_cookie_jar/enhanced_cookie_jar.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/cf_clearance_authority.dart';
import 'package:fluxdo/services/network/cookie/cookie_value_codec.dart';

/// 「在位值粘性」的契约。
///
/// 定稿规则:jar 里的当前 clearance 只要"还能用"(未过期、未临期、未被撞),
/// 任何同步来源不得用不同的值替换它;允许替换的条件:jar 空 / 过期 /
/// 临期 / 刚被撞。不判候选值死活(判不了),只看在位值死没死(判得出)。
///
/// 两类事故在该口径下同时消失:
/// - 2026-08-19「过一次盾只管一次」:过盾后的新值是在位值,残留旧副本
///   (CHIPS 分区,删不掉)再也无法顶替;
/// - 2026-08-22「每次启动弹盾」:jar 空时一切 sync 放行,恢复路径与
///   0.2.26 同样畅通,不存在被堵的可能。
void main() {
  late CfClearanceAuthority authority;

  CanonicalCookie clearance(String value, {DateTime? expiresAt}) =>
      CanonicalCookie(
        name: 'cf_clearance',
        value: value,
        expiresAt: expiresAt,
      );

  void jarWith(CanonicalCookie? cookie) {
    authority.debugCookieReader =
        cookie == null ? () async => null : () async => cookie;
  }

  setUp(() {
    authority = CfClearanceAuthority.instance..debugResetAll();
    authority.debugCookieReader = null;
    authority.debugNow = null;
  });

  tearDown(() {
    authority.debugCookieReader = null;
    authority.debugNow = null;
    authority.debugResetAll();
  });

  group('evaluateReplacement 放行条件', () {
    test('jar 空 → 放行(恢复路径全开,与 0.2.26 一致)', () async {
      jarWith(null);
      expect(
        await authority.evaluateReplacement('any-candidate'),
        CfClearanceReplaceDecision.allow,
      );
    });

    test('候选值与在位值相同 → 幂等跳过', () async {
      jarWith(clearance('v1', expiresAt: DateTime.now().add(const Duration(days: 7))));
      expect(
        await authority.evaluateReplacement('v1'),
        CfClearanceReplaceDecision.skipSameValue,
      );
    });

    test('在位值已过期 → 放行(自然换届)', () async {
      jarWith(clearance('old', expiresAt: DateTime.now().subtract(const Duration(minutes: 1))));
      expect(
        await authority.evaluateReplacement('new-mint'),
        CfClearanceReplaceDecision.allow,
      );
    });

    test('在位值临期(<30 分钟) → 放行(新铸值无缝继位,零弹盾)', () async {
      jarWith(clearance('old', expiresAt: DateTime.now().add(const Duration(minutes: 10))));
      expect(
        await authority.evaluateReplacement('new-mint'),
        CfClearanceReplaceDecision.allow,
      );
    });

    test('在位值刚被撞(已死) → 放行(过盾新值继位/新铸值补位)', () async {
      final expires = DateTime.now().add(const Duration(days: 7));
      jarWith(clearance('dead-value', expiresAt: expires));
      authority.noteIncumbentChallenged('dead-value');

      expect(
        await authority.evaluateReplacement('fresh-from-verify'),
        CfClearanceReplaceDecision.allow,
      );
    });
  });

  group('evaluateReplacement 保护条件(核心)', () {
    test('在位值健康 + 异值候选 → 拒绝顶替(2026-08-19 残留旧值场景)', () async {
      // jar 里是刚过盾的新值(597 字符形态,有效期 7 天)
      jarWith(clearance('fresh-597', expiresAt: DateTime.now().add(const Duration(days: 7))));

      // Turnstile WebView load_stop 带回 14:21 签发的残留旧值(533 字符形态):
      // 即便它的 expires 更晚也不许顶替——判定不看候选值,只看在位值活着。
      expect(
        await authority.evaluateReplacement('stale-533-residue'),
        CfClearanceReplaceDecision.skipHealthyIncumbent,
      );
      // 新铸的 Turnstile 值同样不许顶替(在位值能用就不换)
      expect(
        await authority.evaluateReplacement('new-turnstile-mint'),
        CfClearanceReplaceDecision.skipHealthyIncumbent,
      );
    });

    test('在位值无 expires(session 形态)且未被撞 → 同样受保护', () async {
      jarWith(clearance('session-form-value'));
      expect(
        await authority.evaluateReplacement('other-value'),
        CfClearanceReplaceDecision.skipHealthyIncumbent,
      );
    });
  });

  group('2026-08-19 事故时间线重放', () {
    test('过盾 → 残留值多次试图顶替 → 全部被挡 → 不再二次撞盾', () async {
      // 16:04:54 旧值被撞
      jarWith(clearance('old-533-15_55', expiresAt: DateTime.now().add(const Duration(days: 7))));
      authority.noteIncumbentChallenged('old-533-15_55');

      // 过盾:验证流程删空 jar → 新值(597)经 acceptValues 写入(jar 空,放行)
      jarWith(null);
      expect(await authority.evaluateReplacement('fresh-597'),
          CfClearanceReplaceDecision.allow);
      jarWith(clearance('fresh-597', expiresAt: DateTime.now().add(const Duration(days: 7))));

      // 16:05:00 / 16:05:09 / 16:05:16 三次 load_stop 带回同一枚残留 533:
      // 原日志里每次都盖掉新值、1 秒后再 403;现在全部跳过
      for (var i = 0; i < 3; i++) {
        expect(
          await authority.evaluateReplacement('stale-533-14_21'),
          CfClearanceReplaceDecision.skipHealthyIncumbent,
          reason: '残留旧值第 ${i + 1} 次顶替必须被挡',
        );
      }
      // jar 里始终是 597,后续 timings 带 597 → 200,循环不存在
    });
  });

  group('编码归一化与标记管理', () {
    test('编码形态与解码形态互相命中(在位比较/被撞标记)', () async {
      const raw = 'clear{"ace}';
      final encoded = CookieValueCodec.encode(raw);
      jarWith(clearance(encoded, expiresAt: DateTime.now().add(const Duration(days: 7))));

      // 候选为解码形态 → 命中同值幂等
      expect(
        await authority.evaluateReplacement(raw),
        CfClearanceReplaceDecision.skipSameValue,
      );

      // 以解码形态登记被撞 → 在位(编码形态)判定为已死
      authority.noteIncumbentChallenged(raw);
      expect(
        await authority.evaluateReplacement('another-value'),
        CfClearanceReplaceDecision.allow,
      );
    });

    test('reset 清空被撞标记(登出换账号)', () async {
      jarWith(clearance('v1', expiresAt: DateTime.now().add(const Duration(days: 7))));
      authority.noteIncumbentChallenged('v1');
      authority.reset();

      // reset 后 v1 不再视为已死:异值候选被拒绝
      expect(
        await authority.evaluateReplacement('other'),
        CfClearanceReplaceDecision.skipHealthyIncumbent,
      );
    });

    test('null/空值登记为 no-op', () {
      authority.noteIncumbentChallenged(null);
      authority.noteIncumbentChallenged('');
      // 无异常即通过
    });
  });

  group('撞盾先换值重放的依据(已知死值 / WebView 观察值)', () {
    test('被撞过的值全程记为已知死值,不止最近一枚', () async {
      authority.noteIncumbentChallenged('dead-1');
      authority.noteIncumbentChallenged('dead-2');
      expect(authority.isKnownChallenged('dead-1'), isTrue);
      expect(authority.isKnownChallenged('dead-2'), isTrue);
      expect(authority.isKnownChallenged('alive'), isFalse);
      expect(authority.isKnownChallenged(null), isFalse);
      expect(authority.isKnownChallenged(''), isFalse);

      // 换届闸门契约不变:只看最近一次被撞的在位值
      final expires = DateTime.now().add(const Duration(days: 7));
      jarWith(clearance('dead-1', expiresAt: expires));
      expect(
        await authority.evaluateReplacement('other'),
        CfClearanceReplaceDecision.skipHealthyIncumbent,
      );
      jarWith(clearance('dead-2', expiresAt: expires));
      expect(
        await authority.evaluateReplacement('other'),
        CfClearanceReplaceDecision.allow,
      );
    });

    test('已知死值按编码归一化命中', () {
      const raw = 'clear{"ace}';
      authority.noteIncumbentChallenged(CookieValueCodec.encode(raw));
      expect(authority.isKnownChallenged(raw), isTrue);
    });

    test('WebView 观察值:首次为新铸值,之后视为见过;闸门决定不受影响', () async {
      expect(authority.hasObservedWebViewValue('mint-1'), isFalse);
      authority.noteWebViewValueObserved('mint-1');
      expect(authority.hasObservedWebViewValue('mint-1'), isTrue);
      expect(
        authority.hasObservedWebViewValue(CookieValueCodec.encode('mint-1')),
        isTrue,
      );
      expect(authority.hasObservedWebViewValue(null), isFalse);

      // 在位值健康时,本会话新铸值同样不许顶替(2026-08-19 契约不放松)
      jarWith(clearance('fresh-597', expiresAt: DateTime.now().add(const Duration(days: 7))));
      expect(
        await authority.evaluateReplacement('mint-1'),
        CfClearanceReplaceDecision.skipHealthyIncumbent,
      );
      expect(
        await authority.evaluateReplacement('never-seen'),
        CfClearanceReplaceDecision.skipHealthyIncumbent,
      );
    });

    test('观察集合有界:超出上限淘汰最早登记的值', () {
      for (var i = 0; i < 20; i++) {
        authority.noteWebViewValueObserved('v$i');
      }
      expect(authority.hasObservedWebViewValue('v0'), isFalse);
      expect(authority.hasObservedWebViewValue('v3'), isFalse);
      expect(authority.hasObservedWebViewValue('v4'), isTrue);
      expect(authority.hasObservedWebViewValue('v19'), isTrue);
    });

    test('reset 同时清空已知死值与观察值', () {
      authority.noteIncumbentChallenged('dead');
      authority.noteWebViewValueObserved('seen');
      authority.reset();
      expect(authority.isKnownChallenged('dead'), isFalse);
      expect(authority.hasObservedWebViewValue('seen'), isFalse);
    });
  });

  group('按 host 的可用性账本', () {
    const main = 'linux.do';
    const cdk = 'cdk.linux.do';
    late DateTime now;

    void advance(Duration d) => now = now.add(d);

    setUp(() {
      now = DateTime(2026, 10, 15, 12);
      authority.debugNow = () => now;
    });

    CanonicalCookie live(String value, {Duration ttl = const Duration(days: 7)}) =>
        CanonicalCookie(
          name: 'cf_clearance',
          value: value,
          domain: '.linux.do',
          expiresAt: now.add(ttl),
        );

    test('bootstrap 被 CF 挡下 → 请求门与原生预加载都不可信', () async {
      jarWith(live('v1'));
      expect(
        (await authority.status(main, purpose: CfClearancePurpose.requestGate))
            .usable,
        isTrue,
      );

      authority.noteRejected(main, value: 'v1');

      for (final purpose in [
        CfClearancePurpose.requestGate,
        CfClearancePurpose.nativePreload,
      ]) {
        final status = await authority.status(main, purpose: purpose);
        expect(status.verdict, CfClearanceVerdict.recentlyRejected);
        expect(status.present, isTrue, reason: '值还在，只是不可信');
      }
    });

    test('被拒窗口：jar 换上别的值即解除，否则 2 分钟后自然过期', () async {
      jarWith(live('v1'));
      authority.noteRejected(main, value: 'v1');

      jarWith(live('v2'));
      expect(
        (await authority.status(main, purpose: CfClearancePurpose.requestGate))
            .usable,
        isTrue,
        reason: '被拒的是 v1，新值不受牵连',
      );

      jarWith(live('v1'));
      advance(const Duration(minutes: 1, seconds: 59));
      expect(
        (await authority.status(main, purpose: CfClearancePurpose.requestGate))
            .verdict,
        CfClearanceVerdict.recentlyRejected,
      );
      advance(const Duration(seconds: 1));
      expect(
        (await authority.status(main, purpose: CfClearancePurpose.requestGate))
            .usable,
        isTrue,
      );
    });

    test('不知道被拒的是哪枚时窗口内一律不可信，拿到新值后显式解除', () async {
      jarWith(live('v1'));
      authority.noteRejected(main);
      jarWith(live('v2'));
      expect(
        (await authority.status(main, purpose: CfClearancePurpose.requestGate))
            .verdict,
        CfClearanceVerdict.recentlyRejected,
      );

      authority.clearRejection(main);
      expect(
        (await authority.status(main, purpose: CfClearancePurpose.requestGate))
            .usable,
        isTrue,
      );
    });

    test('拒绝只记在被拒的 host 上', () async {
      jarWith(live('v1'));
      authority.noteRejected(cdk, value: 'v1');
      expect(
        (await authority.status(main, purpose: CfClearancePurpose.requestGate))
            .usable,
        isTrue,
      );
    });

    test('cdk 上定稿值无效 → 只冷却 cdk，主站与其他子域不受影响', () {
      authority.startIneffectiveCooldown(cdk);

      expect(authority.isCoolingDown(cdk), isTrue);
      expect(authority.isCoolingDown(main), isFalse);
      expect(authority.isCoolingDown('credit.linux.do'), isFalse);

      advance(CfClearanceAuthority.ineffectiveCooldown);
      advance(const Duration(milliseconds: 1));
      expect(authority.isCoolingDown(cdk), isFalse);
    });

    test('验证本身连续失败是全站冷却：子域也不再起验证', () {
      authority.recordVerifyFailure(round: 1);
      authority.recordVerifyFailure(round: 1);
      authority.recordVerifyFailure(round: 2);
      expect(authority.isCoolingDown(main), isFalse, reason: '同一轮只记一次');

      authority.recordVerifyFailure(round: 3);
      expect(authority.isCoolingDown(main), isTrue);
      expect(authority.isCoolingDown(cdk), isTrue);
      expect(authority.consecutiveFailures(main), 3);

      authority.resetCooldown();
      expect(authority.isCoolingDown(cdk), isFalse);
      expect(authority.consecutiveFailures(main), 0);
    });

    test('被撞标记按 host 记：cdk 撞过的值在主站仍可用', () async {
      jarWith(live('v1'));
      authority.noteIncumbentChallenged('v1', host: cdk);

      expect(
        (await authority.status(cdk, purpose: CfClearancePurpose.requestGate))
            .verdict,
        CfClearanceVerdict.challenged,
      );
      expect(
        (await authority.status(main, purpose: CfClearancePurpose.requestGate))
            .usable,
        isTrue,
      );
      expect(authority.isKnownChallenged('v1'), isTrue, reason: '不分 host 的查询');
      expect(authority.isKnownChallenged('v1', host: main), isFalse);
      expect(authority.isKnownChallenged('v1', host: cdk), isTrue);
      // jar 里只有这一枚：任一 host 撞过都放开换届
      expect(
        await authority.evaluateReplacement('v2'),
        CfClearanceReplaceDecision.allow,
      );
    });

    group('有效期窗口', () {
      Future<CfClearanceVerdict> verdictFor(
        Duration ttl,
        CfClearancePurpose purpose,
      ) async {
        jarWith(live('v', ttl: ttl));
        return (await authority.status(main, purpose: purpose)).verdict;
      }

      test('剩 5 分钟：原生预加载不够（10 分钟），请求门与续期够用', () async {
        const ttl = Duration(minutes: 5);
        expect(
          await verdictFor(ttl, CfClearancePurpose.nativePreload),
          CfClearanceVerdict.expiring,
        );
        expect(
          await verdictFor(ttl, CfClearancePurpose.requestGate),
          CfClearanceVerdict.usable,
        );
        expect(
          await verdictFor(ttl, CfClearancePurpose.refresh),
          CfClearanceVerdict.usable,
        );
      });

      test('剩 20 秒：请求门也不够（30 秒）', () async {
        expect(
          await verdictFor(
            const Duration(seconds: 20),
            CfClearancePurpose.requestGate,
          ),
          CfClearanceVerdict.expiring,
        );
      });

      test('刚好 10 分钟 / 30 秒：门槛是闭区间', () async {
        expect(
          await verdictFor(
            const Duration(minutes: 10),
            CfClearancePurpose.nativePreload,
          ),
          CfClearanceVerdict.usable,
        );
        expect(
          await verdictFor(
            const Duration(seconds: 30),
            CfClearancePurpose.requestGate,
          ),
          CfClearanceVerdict.usable,
        );
      });

      test('已过期：任何用途都不可用，续期也读不到', () async {
        for (final purpose in CfClearancePurpose.values) {
          jarWith(live('v', ttl: const Duration(minutes: -1)));
          final status = await authority.status(main, purpose: purpose);
          expect(status.verdict, CfClearanceVerdict.expired);
          expect(status.present, isFalse);
        }
      });

      test('无 expires 的会话形态视为够用', () async {
        jarWith(
          CanonicalCookie(
            name: 'cf_clearance',
            value: 'session-form',
            domain: '.linux.do',
          ),
        );
        expect(
          (await authority.status(
            main,
            purpose: CfClearancePurpose.nativePreload,
          )).usable,
          isTrue,
        );
      });

      test('没有 / 不属于本站域名', () async {
        jarWith(null);
        expect(
          (await authority.status(
            main,
            purpose: CfClearancePurpose.requestGate,
          )).verdict,
          CfClearanceVerdict.missing,
        );
        jarWith(
          CanonicalCookie(
            name: 'cf_clearance',
            value: 'x',
            domain: '.example.com',
            expiresAt: now.add(const Duration(days: 1)),
          ),
        );
        final foreign = await authority.status(
          main,
          purpose: CfClearancePurpose.requestGate,
        );
        expect(foreign.verdict, CfClearanceVerdict.foreignDomain);
        expect(foreign.present, isFalse);
      });

      test('闸门的换届窗口仍是 30 分钟', () async {
        jarWith(live('old', ttl: const Duration(minutes: 29)));
        expect(
          await authority.evaluateReplacement('new'),
          CfClearanceReplaceDecision.allow,
        );
        jarWith(live('old', ttl: const Duration(minutes: 31)));
        expect(
          await authority.evaluateReplacement('new'),
          CfClearanceReplaceDecision.skipHealthyIncumbent,
        );
      });
    });

    test('验证轮次定稿值在落值期间直接继位', () async {
      jarWith(live('someone-else-wrote'));
      authority.expectVerifiedSuccessor('verified');
      expect(
        await authority.evaluateReplacement('verified'),
        CfClearanceReplaceDecision.allow,
      );
      expect(
        await authority.evaluateReplacement('other'),
        CfClearanceReplaceDecision.skipHealthyIncumbent,
      );
      authority.expectVerifiedSuccessor(null);
      expect(
        await authority.evaluateReplacement('verified'),
        CfClearanceReplaceDecision.skipHealthyIncumbent,
      );
    });
  });

  group('extractFromCookieHeader', () {
    test('提取与误匹配', () {
      expect(
        CfClearanceAuthority.extractFromCookieHeader(
          '_t=token; cf_clearance=abc.def-_123; _forum_session=s',
        ),
        'abc.def-_123',
      );
      expect(
        CfClearanceAuthority.extractFromCookieHeader('my_cf_clearance=bad; _t=x'),
        isNull,
      );
      expect(CfClearanceAuthority.extractFromCookieHeader(''), isNull);
      expect(CfClearanceAuthority.extractFromCookieHeader(null), isNull);
    });
  });
}
