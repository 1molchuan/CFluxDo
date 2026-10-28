import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/accounts/account_verification.dart';
import 'package:fluxdo/services/session/session_token_ports.dart';

/// 按顺序给出探测结果；null 表示这一次探测抛异常
class _Probe {
  _Probe(this.results);

  final List<SessionTokenProbeResult?> results;
  int calls = 0;

  Future<SessionTokenProbeResult> call() async {
    final result = results[calls++];
    if (result == null) throw Exception('network');
    return result;
  }
}

Future<AccountCheckResult> _verify(
  _Probe probe, {
  Map<String, dynamic>? preloaded,
  void Function()? onPreload,
}) => verifySwitchedAccount(
  userId: 7,
  probe: probe.call,
  preloadedUser: () async {
    onPreload?.call();
    return preloaded;
  },
  retryDelay: Duration.zero,
);

void main() {
  test('探测确认是目标账号：直接确认，不等首页预加载', () async {
    var preloadAwaited = false;
    final probe = _Probe([
      const SessionTokenProbeResult.valid({'id': 7, 'username': 'b'}),
    ]);
    final result = await _verify(probe, onPreload: () => preloadAwaited = true);
    expect(result.check, AccountCheck.confirmed);
    expect(result.user?['username'], 'b');
    expect(preloadAwaited, isFalse);
  });

  test('探测无结论、首页预加载是目标账号：确认，不再重试探测', () async {
    final probe = _Probe([null]);
    final result = await _verify(probe, preloaded: {'id': 7, 'username': 'b'});
    expect(result.check, AccountCheck.confirmed);
    expect(result.user?['username'], 'b');
    expect(probe.calls, 1);
  });

  test('探测无结论、预加载也没有用户：重试探测成功', () async {
    final probe = _Probe([
      const SessionTokenProbeResult.inconclusive(
        networkFailure: true,
        statusCode: 403,
      ),
      const SessionTokenProbeResult.valid({'id': 7}),
    ]);
    final result = await _verify(probe);
    expect(result.check, AccountCheck.confirmed);
    expect(probe.calls, 2);
  });

  test('网络一直不通：没有结论，不当成失效', () async {
    final probe = _Probe([null, null]);
    final result = await _verify(probe);
    expect(result.check, AccountCheck.unknown);
    expect(probe.calls, 2);
  });

  test('撞盾一直无结论：没有结论', () async {
    final probe = _Probe([
      const SessionTokenProbeResult.inconclusive(statusCode: 403),
      const SessionTokenProbeResult.inconclusive(statusCode: 403),
    ]);
    expect((await _verify(probe)).check, AccountCheck.unknown);
  });

  test('服务端明确拒绝：失效', () async {
    final probe = _Probe([
      const SessionTokenProbeResult.rejected(statusCode: 404),
    ]);
    expect((await _verify(probe)).check, AccountCheck.rejected);
    expect(probe.calls, 1);
  });

  test('服务端认的是另一个人：不对', () async {
    final probe = _Probe([
      const SessionTokenProbeResult.valid({'id': 9}),
    ]);
    expect((await _verify(probe)).check, AccountCheck.wrongAccount);
  });

  test('预加载是别人、探测确认是目标账号：以服务端为准', () async {
    final probe = _Probe([
      const SessionTokenProbeResult.valid({'id': 7}),
    ]);
    final result = await _verify(probe, preloaded: {'id': 9});
    expect(result.check, AccountCheck.confirmed);
  });

  test('预加载是别人、探测无结论：按不对处理', () async {
    final probe = _Probe([null, null]);
    final result = await _verify(probe, preloaded: {'id': 9});
    expect(result.check, AccountCheck.wrongAccount);
  });

  test('首页预加载只等一次', () async {
    var preloadCalls = 0;
    final probe = _Probe([null, null]);
    await _verify(probe, onPreload: () => preloadCalls++);
    expect(preloadCalls, 1);
  });

  test('current_user 没有 id：当无结论继续问', () async {
    final probe = _Probe([
      const SessionTokenProbeResult.valid({'username': 'b'}),
      const SessionTokenProbeResult.valid({'id': 7}),
    ]);
    expect((await _verify(probe)).check, AccountCheck.confirmed);
    expect(probe.calls, 2);
  });
}
