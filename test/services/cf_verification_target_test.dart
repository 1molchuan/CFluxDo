import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/config/forum_site.dart';
import 'package:fluxdo/services/cf_verification_round.dart';
import 'package:fluxdo/services/network/cf/cf_verification_target.dart';

import 'cf_round_fakes.dart';

void main() {
  CfVerificationTarget target() => CfVerificationTarget(
    primary: ForumSite.idcFlare.cfVerificationUri,
    fallback: ForumSite.idcFlare.cfVerificationFallbackUri,
  );
  Map<String, Object> home() => {
    'href': 'https://idcflare.com/',
    'hasBootstrap': true,
    'hasChallenge': false,
    'originNotFound': false,
  };
  bool passed(
    CfVerificationTarget entry,
    String url,
    int status, {
    bool mainFrame = true,
    bool challenge = false,
  }) => entry.isConclusiveResponse(
    url: Uri.parse(url),
    statusCode: status,
    isMainFrame: mainFrame,
    cfMitigated: challenge,
  );

  test('站点分别配置入口，LINUX DO 不新增导航，IDC 最多一个同站备用入口', () {
    expect(
      ForumSite.linuxDo.cfVerificationUri.toString(),
      'https://linux.do/challenge',
    );
    expect(ForumSite.linuxDo.cfVerificationFallbackUri, isNull);
    final entry = target();
    expect(entry.current.toString(), 'https://idcflare.com/');
    expect(entry.canUseFallback, isTrue);
    expect(
      entry.useFallback(home()).toString(),
      'https://idcflare.com/challenge',
    );
    expect(entry.canUseFallback, isFalse);
    expect(entry.useFallback(home()), isNull);
  });

  test('落值后回首页：首页是入口同源的 /，只认同源首页', () {
    final linuxDo = CfVerificationTarget(
      primary: ForumSite.linuxDo.cfVerificationUri,
    );
    expect(linuxDo.home.toString(), 'https://linux.do/');
    expect(target().home.toString(), 'https://idcflare.com/');
    expect(linuxDo.isHome(Uri.parse('https://linux.do/')), isTrue);
    expect(linuxDo.isHome(Uri.parse('https://linux.do')), isTrue);
    expect(
      linuxDo.isHome(Uri.parse('https://linux.do/?__cf_chl_tk=x')),
      isTrue,
      reason: 'CF 过盾跳转可能残留查询参数',
    );
    expect(linuxDo.isHome(Uri.parse('https://linux.do/challenge')), isFalse);
    expect(linuxDo.isHome(Uri.parse('https://credit.linux.do/')), isFalse);
    expect(linuxDo.isHome(Uri.parse('http://linux.do/')), isFalse);
  });

  test('正常首页里的后台 Turnstile 不等于整页挑战，真正挑战标记仍优先', () {
    const widget = '<div class="cf-turnstile"></div>';
    const home =
        '<meta id="data-discourse-setup"><script id="data-preloaded" type="application/json">{}</script>';
    expect(CfVerificationTarget.hasActiveChallenge(widget), isTrue);
    expect(CfVerificationTarget.hasActiveChallenge(home + widget), isFalse);
    expect(
      CfVerificationTarget.hasActiveChallenge(
        '$home$widget<script>window._cf_chl_opt={}</script>',
      ),
      isTrue,
    );
    expect(
      CfVerificationTarget.hasActiveChallenge(
        '<p>data-discourse-setup data-preloaded</p>$widget',
      ),
      isTrue,
    );
  });

  test('首页普通成功响应或普通 404 不能被当作 Cookie 已定稿', () {
    final entry = target();
    expect(passed(entry, 'https://idcflare.com/', 200), isFalse);
    expect(passed(entry, 'https://idcflare.com/', 404), isFalse);
    expect(passed(entry, 'https://idcflare.com/challenge', 404), isFalse);
    entry.useFallback(home());
    expect(passed(entry, 'https://idcflare.com/challenge', 404), isTrue);
    expect(passed(entry, 'https://idcflare.com/challenge', 200), isFalse);
  });

  test('只认同源、无挑战、无 query 的主文档 /challenge 404', () {
    final entry = target()..useFallback(home());
    for (final url in [
      'http://idcflare.com/challenge',
      'https://idcflare.com:8443/challenge',
      'https://idcflare.com.evil.test/challenge',
      'https://linux.do/challenge',
      'https://user@idcflare.com/challenge',
      'https://idcflare.com/challenge?__cf_chl_tk=temporary',
    ]) {
      expect(passed(entry, url, 404), isFalse, reason: url);
    }
    expect(
      passed(entry, 'https://idcflare.com/challenge', 404, mainFrame: false),
      isFalse,
    );
    expect(
      passed(entry, 'https://idcflare.com/challenge', 404, challenge: true),
      isFalse,
    );
    expect(passed(entry, 'https://idcflare.com/challenge', 503), isFalse);
  });

  test('挑战仍在、空白页、外站、异常快照都不能触发备用导航', () {
    for (final snapshot in <Object?>[
      null,
      [],
      'bad json',
      {...home(), 'hasChallenge': true},
      {...home(), 'hasBootstrap': false},
      {...home(), 'hasChallenge': 'false'},
      {...home(), 'href': 'https://linux.do/'},
      {...home(), 'href': 'https://idcflare.com:8443/'},
      {...home(), 'href': 'https://idcflare.com/?__cf_chl_tk=temporary'},
    ]) {
      final entry = target();
      expect(entry.useFallback(snapshot), isNull, reason: '$snapshot');
      expect(entry.current.toString(), 'https://idcflare.com/');
    }
  });

  test('支持 WebView JSON 快照，首页明确不存在时也只回退一次', () {
    final entry = target();
    final snapshot = {...home(), 'hasBootstrap': false, 'originNotFound': true};
    expect(entry.useFallback(jsonEncode(snapshot))?.path, '/challenge');
    expect(entry.useFallback(snapshot), isNull);
  });

  test('备用 URL 本身必须同源且为固定 /challenge，不接受跳站或带参数 URL', () {
    for (final fallback in [
      'https://linux.do/challenge',
      'https://idcflare.com:8443/challenge',
      'https://idcflare.com/challenge?q=1',
      'https://idcflare.com/challenge#fragment',
      'https://idcflare.com/login',
    ]) {
      final entry = CfVerificationTarget(
        primary: Uri.parse('https://idcflare.com/'),
        fallback: Uri.parse(fallback),
      );
      expect(entry.useFallback(home()), isNull, reason: fallback);
    }
  });

  test('首页 200 不收口，备用入口 404 之后仍须候选 Cookie 真正落 jar', () async {
    final clock = FakeRoundClock();
    final env = FakeRoundEnvironment(clock)
      ..webView = 'retained-clearance'
      ..staleWebView = 'retained-clearance';
    final rounds = CfVerificationRounds(environment: env, clock: clock);
    env.rounds = rounds;
    final outcome = rounds.verify(mode: CfVerifyMode.foreground);
    await pumpEventQueue();
    final round = env.presented!;
    final entry = target();
    if (passed(entry, 'https://idcflare.com/', 200)) {
      round.completionHint('普通首页', conclusive: true);
    }
    await clock.advance(const Duration(seconds: 4));
    expect(round.isDone, isFalse);
    expect(env.landed, isEmpty);
    entry.useFallback(home());
    if (passed(entry, 'https://idcflare.com/challenge', 404)) {
      round.completionHint('备用入口源站 404', conclusive: true);
    }
    await clock.advance(const Duration(seconds: 4));
    final result = await outcome;
    expect(result, isA<CfRoundPassed>());
    expect(env.jar, 'retained-clearance');
    expect(env.landed, ['retained-clearance']);
  });

  test('备用入口返回 404 但没有 Cookie，不能伪造成功', () async {
    final clock = FakeRoundClock();
    final env = FakeRoundEnvironment(clock);
    final rounds = CfVerificationRounds(environment: env, clock: clock);
    env.rounds = rounds;
    final outcome = rounds.verify(mode: CfVerifyMode.foreground);
    await pumpEventQueue();
    final entry = target()..useFallback(home());
    if (passed(entry, 'https://idcflare.com/challenge', 404)) {
      env.presented!.completionHint('备用入口源站 404', conclusive: true);
    }
    await clock.advance(const Duration(seconds: 9));
    expect((await outcome as CfRoundFailed).reason, CfRoundFailure.notLanded);
    expect(env.jar, 'old');
    expect(env.landed, isEmpty);
  });
}
