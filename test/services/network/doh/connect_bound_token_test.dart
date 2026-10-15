import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/network/doh/accel_doh_api.dart';
import 'package:fluxdo/services/network/doh/cfhub_api.dart';
import 'package:fluxdo/services/network/doh/connect_bound_token.dart';
import 'package:fluxdo/services/network/doh/connect_code_flow.dart';

import 'connect_token_fakes.dart';

/// 同一套用例分别跑加速 DoH 和 cfhub 探针两份配置
void main() {
  for (final (name, policy) in [
    ('加速 DoH', AccelDohApi.policy),
    ('cfhub 探针', CfhubApi.policy),
  ]) {
    group('ConnectBoundToken · $name', () {
      late FakeTokenServer server;
      late FakeConnectFlow flow;
      late List<Duration> sleeps;
      Future<void> Function()? onSleep;
      int? userId;
      late ConnectBoundToken bound;

      ConnectBoundToken build([ConnectTokenTransport? transport]) =>
          ConnectBoundToken(
            policy: policy,
            transport: transport ?? server.transport(),
            flow: () => flow,
            currentUserId: () => userId,
            sleep: (delay) async {
              sleeps.add(delay);
              await onSleep?.call();
            },
          );

      Future<ConnectTokenResult> authorize({bool interactive = true}) =>
          bound.authorize(userId: 7, interactive: interactive);

      setUp(() {
        server = FakeTokenServer(policy);
        flow = FakeConnectFlow();
        sleeps = [];
        onSleep = null;
        userId = 7;
        bound = build();
      });

      // 手动授权网络类失败时总共会走几遍
      final manualAttempts = policy.retryDelays.length + 1;
      final noManualRetry = policy.retryDelays.isEmpty ? '这份配置的手动授权不重来' : false;

      test('正常流程：取授权地址 → Connect → 换码，拿到令牌', () async {
        final result = await authorize();
        expect(result.outcome, ConnectTokenOutcome.issued);
        expect(result.token, FakeTokenServer.issuedToken);
        expect(result.lifetime, policy.defaultLifetime);
        expect(server.paths, [policy.startPath, policy.tokenPath]);

        final start = server.calls.first;
        expect(start.body, isEmpty);
        expect(start.bearer, isNull);
        expect(start.oneShot, isFalse);
        final exchange = server.calls.last;
        expect(exchange.body, {'code': 'the-code', 'state': 'the-state'});
        expect(exchange.bearer, isNull);
        expect(exchange.oneShot, isTrue);

        final connect = flow.calls.single;
        expect(connect.url.toString(), FakeTokenServer.authorizeUrl);
        expect(connect.silent, isFalse);
        expect(connect.requestTag, policy.connectRequestTag);
        expect(bound.lastFailureDetail, isNull);
      });

      test('后台静默授权：Connect 按 silent 走', () async {
        final result = await authorize(interactive: false);
        expect(result.outcome, ConnectTokenOutcome.issued);
        expect(flow.calls.single.silent, isTrue);
      });

      test('服务端给了 expires_in 就按它算有效期', () async {
        server.respond(policy.tokenPath, 200, {
          'token': 'cfp_x',
          'expires_in': 3600,
        });
        final result = await authorize();
        expect(result.lifetime, const Duration(hours: 1));
      });

      test('授权地址不是 connect.linux.do 的授权页：failed，不走 Connect', () async {
        const bad = [
          'https://evil.example.com/oauth2/authorize?client_id=x',
          'https://connect.linux.do.evil.com/oauth2/authorize',
          'http://connect.linux.do/oauth2/authorize',
          'https://connect.linux.do/other',
          'https://linux.do/oauth2/authorize',
        ];
        for (final url in bad) {
          server.respond(policy.startPath, 200, {'authorize_url': url});
          final result = await authorize(interactive: false);
          expect(result.outcome, ConnectTokenOutcome.failed, reason: url);
          expect(bound.lastFailureDetail, 'start bad url', reason: url);
        }
        for (final body in ['{}', '[]']) {
          server.reply(policy.startPath, (_) => (200, body));
          final result = await authorize(interactive: false);
          expect(result.outcome, ConnectTokenOutcome.failed, reason: body);
          expect(bound.lastFailureDetail, 'start bad url', reason: body);
        }
        server.reply(policy.startPath, (_) => (200, 'not json'));
        expect(
          (await authorize(interactive: false)).outcome,
          ConnectTokenOutcome.failed,
        );
        expect(bound.lastFailureDetail, 'start FormatException');
        expect(flow.calls, isEmpty);
        expect(server.count(policy.tokenPath), 0);
      });

      test('取授权地址失败：失败说明带上卡在哪一步', () async {
        for (final status in [401, 403, 500, 502]) {
          server.respond(policy.startPath, status);
          final result = await authorize(interactive: false);
          expect(result.outcome, ConnectTokenOutcome.failed, reason: '$status');
          expect(bound.lastFailureDetail, 'start HTTP $status');
        }
        server.reply(policy.startPath, (_) => throw const SocketException('x'));
        await authorize(interactive: false);
        expect(bound.lastFailureDetail, 'start SocketException');
      });

      test('404：cfhub 当接口未开放，加速当普通失败', () async {
        server.respond(policy.startPath, 404);
        final start = await authorize();
        server.respond(policy.startPath, 200, {
          'authorize_url': FakeTokenServer.authorizeUrl,
        });
        server.respond(policy.tokenPath, 404);
        final exchange = await authorize();
        if (policy.notFoundMeansUnavailable) {
          expect(start.outcome, ConnectTokenOutcome.serverUnavailable);
          expect(exchange.outcome, ConnectTokenOutcome.serverUnavailable);
          expect(bound.lastFailureDetail, isNull);
          // 未开放不重来
          expect(sleeps, isEmpty);
        } else {
          expect(start.outcome, ConnectTokenOutcome.failed);
          expect(exchange.outcome, ConnectTokenOutcome.failed);
          expect(bound.lastFailureDetail, 'token HTTP 404');
        }
      });

      test('换码 401/403：rejected，不重来', () async {
        for (final status in [401, 403]) {
          server.calls.clear();
          server.respond(policy.tokenPath, status);
          final result = await authorize();
          expect(result.outcome, ConnectTokenOutcome.rejected);
          expect(result.token, isNull);
          expect(server.count(policy.startPath), 1);
          expect(bound.lastFailureDetail, isNull);
        }
        expect(sleeps, isEmpty);
      });

      test('换码其他错误或令牌格式不对：failed', () async {
        for (final status in [400, 429, 500, 503]) {
          server.respond(policy.tokenPath, status);
          final result = await authorize(interactive: false);
          expect(result.outcome, ConnectTokenOutcome.failed);
          expect(bound.lastFailureDetail, 'token HTTP $status');
        }
        for (final token in [
          '',
          42,
          'cfp_有中文',
          if (policy == CfhubApi.policy) 'abc',
          if (policy == CfhubApi.policy) 'cfp_',
        ]) {
          server.respond(policy.tokenPath, 200, {'token': token});
          final result = await authorize(interactive: false);
          expect(result.outcome, ConnectTokenOutcome.failed, reason: '$token');
          expect(result.token, isNull);
          expect(bound.lastFailureDetail, 'token bad body');
        }
      });

      test('网络类失败：手动授权按配置整条链路重来，静默授权只走一次', () async {
        server.reply(policy.startPath, (_) => throw const SocketException('x'));
        final manual = await authorize();
        expect(manual.outcome, ConnectTokenOutcome.failed);
        expect(server.count(policy.startPath), manualAttempts);
        expect(sleeps, policy.retryDelays);
        expect(bound.lastFailureDetail, 'start SocketException');

        server.calls.clear();
        sleeps.clear();
        final silent = await authorize(interactive: false);
        expect(silent.outcome, ConnectTokenOutcome.failed);
        expect(server.count(policy.startPath), 1);
        expect(sleeps, isEmpty);
      });

      test('Connect 网络失败也算网络类失败：重来时换新的授权地址', () async {
        flow.result = const ConnectCodeResult.failed();
        final result = await authorize();
        expect(result.outcome, ConnectTokenOutcome.failed);
        expect(bound.lastFailureDetail, 'connect failed');
        expect(server.count(policy.startPath), manualAttempts);
        expect(flow.calls, hasLength(manualAttempts));
        expect(server.count(policy.tokenPath), 0);
      });

      test('重来一次就成功：拿到令牌，失败说明清空', () async {
        server.once(policy.startPath, (_) => (502, ''));
        final result = await authorize();
        expect(result.outcome, ConnectTokenOutcome.issued);
        expect(server.count(policy.startPath), 2);
        expect(sleeps, [policy.retryDelays.first]);
        expect(bound.lastFailureDetail, isNull);
      }, skip: noManualRetry);

      test('被拒 / Connect 用不了：不重来', () async {
        server.respond(policy.tokenPath, 403);
        expect((await authorize()).outcome, ConnectTokenOutcome.rejected);

        server.respond(policy.tokenPath, 200, {'token': 'cfp_x'});
        flow.result = const ConnectCodeResult.unavailable();
        expect(
          (await authorize()).outcome,
          ConnectTokenOutcome.connectUnavailable,
        );
        expect(server.count(policy.startPath), 2);
        expect(sleeps, isEmpty);
      });

      test('Connect 撞盾没过：failed（connect challenge），不重来', () async {
        flow.result = const ConnectCodeResult.failed(
          failureDetail: 'challenge',
          retryable: false,
        );
        final result = await authorize();
        expect(result.outcome, ConnectTokenOutcome.failed);
        expect(bound.lastFailureDetail, 'connect challenge');
        expect(server.count(policy.startPath), 1);
        expect(sleeps, isEmpty);
      });

      test('Connect 时关掉了过盾验证页：cancelled，不重来', () async {
        flow.result = const ConnectCodeResult.cancelled();
        final result = await authorize();
        expect(result.outcome, ConnectTokenOutcome.cancelled);
        expect(bound.lastFailureDetail, isNull);
        expect(server.count(policy.startPath), 1);
        expect(server.count(policy.tokenPath), 0);
        expect(sleeps, isEmpty);
      });

      test('Rust 侧超时：换码不经 Dart 重发，取授权地址退回 Dart', () async {
        final native = <String>[];
        bound = build(
          server.transport(
            // Rust 那边一直不回
            native: (request) {
              native.add(request.path);
              return Completer<(int, String)?>().future;
            },
            nativeTimeout: const Duration(milliseconds: 20),
          ),
        );
        final result = await authorize(interactive: false);
        expect(native, [policy.startPath, policy.tokenPath]);
        // start 不是一次性请求：Rust 超时后改走 Dart；换码只发了 Rust 那一次
        expect(server.paths, [policy.startPath]);
        expect(result.outcome, ConnectTokenOutcome.failed);
        expect(bound.lastFailureDetail, 'token TimeoutException');
      });

      test('Rust 侧直接失败（没超时）：退回 Dart 发出', () async {
        bound = build(
          server.transport(native: (_) async => throw StateError('rust')),
        );
        final result = await authorize(interactive: false);
        expect(result.outcome, ConnectTokenOutcome.issued);
        expect(server.paths, [policy.startPath, policy.tokenPath]);
      });

      test('Rust 侧给了响应：不再走 Dart', () async {
        bound = build(server.transport(native: server.handle));
        final result = await authorize(interactive: false);
        expect(result.outcome, ConnectTokenOutcome.issued);
        expect(server.paths, [policy.startPath, policy.tokenPath]);
      });

      test('作废还没落地：重新授权先等它，再取授权地址', () async {
        final gate = server.hold(policy.revokePath);
        unawaited(bound.revoke('cfp_old'));
        final pending = authorize();
        await pumpEventQueue();
        expect(server.paths, [policy.revokePath]);

        gate.complete();
        final result = await pending;
        expect(result.outcome, ConnectTokenOutcome.issued);
        expect(server.paths, [
          policy.revokePath,
          policy.startPath,
          policy.tokenPath,
        ]);
        expect(server.revoked, ['cfp_old']);
      });

      test('作废失败也不挡住重新授权', () async {
        server.reply(
          policy.revokePath,
          (_) => throw const SocketException('x'),
        );
        await bound.revoke('cfp_old');
        expect((await authorize()).outcome, ConnectTokenOutcome.issued);
      });

      test('Connect 期间换了号：丢弃，不换码', () async {
        flow.onFetch = () => userId = 8;
        final result = await authorize();
        expect(result.outcome, ConnectTokenOutcome.stale);
        expect(server.count(policy.tokenPath), 0);
        expect(bound.lastFailureDetail, isNull);
      });

      test('Connect 期间换号又换回来（调用方 invalidate）：丢弃', () async {
        flow.onFetch = bound.invalidate;
        final result = await authorize();
        expect(result.outcome, ConnectTokenOutcome.stale);
        expect(server.count(policy.tokenPath), 0);
      });

      test('换码期间退出：丢弃结果，作废刚拿到的令牌', () async {
        server.once(policy.tokenPath, (_) {
          userId = null;
          return (200, '{"token":"cfp_late"}');
        });
        final result = await authorize();
        expect(result.outcome, ConnectTokenOutcome.stale);
        expect(result.token, isNull);
        await pumpEventQueue();
        expect(server.revoked, ['cfp_late']);
      });

      test('取授权地址期间被 invalidate：不走 Connect', () async {
        server.once(policy.startPath, (_) {
          bound.invalidate();
          return (200, '{"authorize_url":"${FakeTokenServer.authorizeUrl}"}');
        });
        expect((await authorize()).outcome, ConnectTokenOutcome.stale);
        expect(flow.calls, isEmpty);
      });

      test('重来前的等待期间换了号：不再重来', () async {
        server.reply(policy.startPath, (_) => throw const SocketException('x'));
        onSleep = () async => userId = 8;
        final result = await authorize();
        expect(result.outcome, ConnectTokenOutcome.stale);
        expect(server.count(policy.startPath), 1);
      }, skip: noManualRetry);

      test(
        '续期：一次性请求，带旧令牌；401 → rejected',
        () async {
          final path = policy.refreshPath!;
          server.respond(path, 200, {'token': 'cfp_new', 'expires_in': 60});
          final ok = await bound.refresh('cfp_old', userId: 7);
          expect(ok.outcome, ConnectTokenOutcome.issued);
          expect(ok.token, 'cfp_new');
          final call = server.lastCall(path)!;
          expect(call.bearer, 'cfp_old');
          expect(call.body, isNull);
          expect(call.oneShot, isTrue);

          server.respond(path, 401);
          expect(
            (await bound.refresh('cfp_new', userId: 7)).outcome,
            ConnectTokenOutcome.rejected,
          );
        },
        skip: policy.refreshPath == null ? '这份配置没有续期' : false,
      );

      test(
        '续期在 Rust 侧超时：不经 Dart 重发',
        () async {
          bound = build(
            server.transport(
              native: (_) => Completer<(int, String)?>().future,
              nativeTimeout: const Duration(milliseconds: 20),
            ),
          );
          final result = await bound.refresh('cfp_old', userId: 7);
          expect(result.outcome, ConnectTokenOutcome.failed);
          expect(server.calls, isEmpty);
        },
        skip: policy.refreshPath == null ? '这份配置没有续期' : false,
      );

      test('续期期间退出：丢弃，作废新令牌', () async {
        final path = policy.refreshPath!;
        server.reply(path, (_) {
          bound.invalidate();
          return (200, '{"token":"cfp_rotated"}');
        });
        final result = await bound.refresh('cfp_old', userId: 7);
        expect(result.outcome, ConnectTokenOutcome.stale);
        await pumpEventQueue();
        expect(server.revoked, ['cfp_rotated']);
      }, skip: policy.refreshPath == null ? '这份配置没有续期' : false);

      test('作废：带 Bearer、无正文，失败吞掉', () async {
        await bound.revoke('cfp_old');
        final call = server.lastCall(policy.revokePath)!;
        expect(call.bearer, 'cfp_old');
        expect(call.body, isNull);
        expect(call.oneShot, isFalse);

        server.respond(policy.revokePath, 500);
        await bound.revoke('cfp_old');
        server.reply(policy.revokePath, (_) => throw StateError('boom'));
        await bound.revoke('cfp_old');
      });
    });
  }
}
