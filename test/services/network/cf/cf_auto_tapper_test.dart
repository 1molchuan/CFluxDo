import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/cf_native_click.dart';
import 'package:fluxdo/services/network/cf/cf_auto_tapper.dart';
import 'package:fluxdo/services/network/cf/cf_tap_policy.dart';

const _point = CfTapLocation.point(nx: 0.3, ny: 0.4, source: 'iframe');

/// 可控的假环境：定位结果按队列给出；「等反馈」的窗口由测试决定何时到点，
/// 其他等待立即结束。
class _Harness {
  _Harness({
    List<CfTapLocation>? locations,
    this.dispatchResult = const CfTapDispatch.ok(),
  }) : locations = locations ?? [_point];

  final List<CfTapLocation> locations;
  CfTapDispatch dispatchResult;
  bool canTap = true;
  int locateCalls = 0;
  final taps = <(double, double)>[];
  final logs = <String>[];
  final effectWindows = <Completer<void>>[];

  /// 注入触摸时 Turnstile 是否立即响应
  bool turnstileReacts = false;

  late final CfAutoTapper tapper = CfAutoTapper(
    locate: () async {
      final i = locateCalls++;
      return locations[i < locations.length ? i : locations.length - 1];
    },
    dispatch: (nx, ny) async {
      taps.add((nx, ny));
      if (dispatchResult.ok && turnstileReacts) {
        scheduleMicrotask(tapper.interactionEnded);
      }
      return dispatchResult;
    },
    canTap: () => canTap,
    log: logs.add,
    delay: (duration) {
      if (duration != CfTapPolicy.effectWindow) return Future<void>.value();
      final window = Completer<void>();
      effectWindows.add(window);
      return window.future;
    },
  );

  /// 让所有挂着的「等反馈」窗口到点
  Future<void> elapseEffectWindows() async {
    for (var round = 0; round < 10; round++) {
      await pumpEventQueue();
      final open = effectWindows.where((w) => !w.isCompleted).toList();
      if (open.isEmpty) return;
      for (final w in open) {
        w.complete();
      }
    }
  }
}

void main() {
  group('CfAutoTapper', () {
    test('点下去后 Turnstile 响应：算点中，只点一次', () async {
      final h = _Harness()..turnstileReacts = true;
      final outcome = await h.tapper.run();
      expect(outcome, CfTapOutcome.effective);
      expect(h.taps, [(0.3, 0.4)]);
    });

    test('没反馈：本回合重试到额度用完', () async {
      final h = _Harness();
      final future = h.tapper.run();
      await h.elapseEffectWindows();
      expect(await future, CfTapOutcome.noEffect);
      expect(h.taps.length, CfTapPolicy.maxAttemptsPerRound);
    });

    test('新回合（interactiveTimeout 后）能再点，但整页不超过上限', () async {
      final h = _Harness();
      for (var round = 0; round < 3; round++) {
        h.tapper.newRound();
        final future = h.tapper.run();
        await h.elapseEffectWindows();
        await future;
      }
      expect(h.taps.length, CfTapPolicy.maxAttemptsPerDocument);
    });

    test('新文档：额度清零', () async {
      final h = _Harness();
      var future = h.tapper.run();
      await h.elapseEffectWindows();
      await future;
      expect(h.tapper.documentAttempts, 2);
      h.tapper.newDocument();
      expect(h.tapper.documentAttempts, 0);
      h.turnstileReacts = true;
      future = h.tapper.run();
      expect(await future, CfTapOutcome.effective);
    });

    test('被遮罩盖住：等一会儿再定位，揭开后再点', () async {
      final h = _Harness(
        locations: const [
          CfTapLocation.unavailable('masked'),
          CfTapLocation.unavailable('masked'),
          _point,
        ],
      )..turnstileReacts = true;
      expect(await h.tapper.run(), CfTapOutcome.effective);
      expect(h.locateCalls, 3);
      expect(h.taps.length, 1);
    });

    test('一直定位不到：不点，也不占额度', () async {
      final h = _Harness(
        locations: const [CfTapLocation.unavailable('occluded')],
      );
      expect(await h.tapper.run(), CfTapOutcome.notLocated);
      expect(h.locateCalls, CfTapPolicy.locateAttempts);
      expect(h.taps, isEmpty);
      expect(h.tapper.documentAttempts, 0);
      expect(h.logs.last, contains('occluded'));
    });

    test('原生端找不到目标 WebView：不重试', () async {
      final h = _Harness(
        dispatchResult: const CfTapDispatch.failed('view_not_found'),
      );
      expect(await h.tapper.run(), CfTapOutcome.dispatchFailed);
      expect(h.taps.length, 1);
    });

    test('条件不满足（纯后台轮次等）：什么都不做', () async {
      final h = _Harness()..canTap = false;
      expect(await h.tapper.run(), CfTapOutcome.skipped);
      expect(h.locateCalls, 0);
    });

    test('等反馈期间换了文档：放弃，不再重试', () async {
      final h = _Harness();
      final future = h.tapper.run();
      await pumpEventQueue();
      h.tapper.newDocument();
      await h.elapseEffectWindows();
      expect(await future, CfTapOutcome.skipped);
      expect(h.taps.length, 1);
    });

    test('用户自己点了（interactiveEnd）：本回合不再点', () async {
      final h = _Harness();
      h.tapper.interactionEnded();
      expect(await h.tapper.run(), CfTapOutcome.skipped);
      expect(h.taps, isEmpty);
    });

    test('running / effectiveAt：点中记时刻，换文档清空', () async {
      final h = _Harness()..turnstileReacts = true;
      expect(h.tapper.effectiveAt, isNull);
      final future = h.tapper.run();
      expect(h.tapper.running, isTrue);
      await future;
      expect(h.tapper.running, isFalse);
      expect(h.tapper.effectiveAt, isNotNull);
      h.tapper.newDocument();
      expect(h.tapper.effectiveAt, isNull);
    });

    test('没点中不记 effectiveAt', () async {
      final h = _Harness();
      final future = h.tapper.run();
      await h.elapseEffectWindows();
      await future;
      expect(h.tapper.effectiveAt, isNull);
    });

    test('并发调用共享同一个流程', () async {
      final h = _Harness()..turnstileReacts = true;
      final results = await Future.wait([h.tapper.run(), h.tapper.run()]);
      expect(results, everyElement(CfTapOutcome.effective));
      expect(h.taps.length, 1);
    });
  });

  group('CfNativeClick.decodeLocation', () {
    test('Android 双层 JSON 字符串', () {
      const raw =
          '"{\\"ok\\":true,\\"x\\":120,\\"y\\":200,\\"vw\\":400,\\"vh\\":800,\\"source\\":\\"iframe\\"}"';
      final location = CfNativeClick.decodeLocation(raw);
      expect(location.found, isTrue);
      expect(location.nx, closeTo(0.3, 1e-9));
      expect(location.ny, closeTo(0.25, 1e-9));
      expect(location.source, 'iframe');
    });

    test('脚本报告的原因原样带回', () {
      final location = CfNativeClick.decodeLocation(
        '{"ok":false,"reason":"masked"}',
      );
      expect(location.found, isFalse);
      expect(location.reason, 'masked');
    });

    test('坏数据 / 缺字段 / 视口为 0 / 点在视口外都不点', () {
      expect(CfNativeClick.decodeLocation(null).reason, 'bad_result');
      expect(CfNativeClick.decodeLocation('not json').reason, 'bad_result');
      expect(
        CfNativeClick.decodeLocation({'ok': true, 'x': 1, 'y': 1}).reason,
        'bad_result',
      );
      expect(
        CfNativeClick.decodeLocation({
          'ok': true,
          'x': 1,
          'y': 1,
          'vw': 0,
          'vh': 10,
        }).reason,
        'bad_result',
      );
      expect(
        CfNativeClick.decodeLocation({
          'ok': true,
          'x': 500,
          'y': 1,
          'vw': 400,
          'vh': 800,
        }).reason,
        'out_of_viewport',
      );
    });
  });
}
