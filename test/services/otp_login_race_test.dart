import 'dart:async';

import 'package:dio/dio.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/otp_login_race.dart';
import 'package:fluxdo/services/user_api_key_service.dart';

/// 拿口令换会话：原生先跑，到点没结果网页再起跑，谁先换到用谁。
void main() {
  const success = OtpRedeemResult.success('new-session');
  const rejected = OtpRedeemResult.failed(OtpRedeemFailure.rejected);
  const challenged = OtpRedeemResult.failed(OtpRedeemFailure.challenge);
  const offline = OtpRedeemResult.failed(OtpRedeemFailure.network);

  late _Host host;
  late Completer<OtpRedeemResult> native;
  late CancelToken nativeCancel;
  late void Function() nativeProgressed;
  late bool verifying;
  OtpLoginOutcome? outcome;

  OtpLoginRace start() {
    host = _Host();
    native = Completer<OtpRedeemResult>();
    verifying = false;
    outcome = null;
    final race = OtpLoginRace(
      redeemNative: (cancelToken, onProgress) {
        nativeCancel = cancelToken;
        nativeProgressed = onProgress;
        return native.future;
      },
      host: host,
      holdWeb: () => verifying,
    );
    unawaited(race.run().then((value) => outcome = value));
    return race;
  }

  test('原生两秒内换到：网页根本不启动', () {
    fakeAsync((async) {
      start();
      async.elapse(const Duration(milliseconds: 1200));
      native.complete(success);
      async.flushMicrotasks();

      expect(outcome, OtpLoginOutcome.nativeSucceeded);
      async.elapse(const Duration(seconds: 30));
      expect(host.events, isEmpty);
    });
  });

  test('原生两步各用了一秒半：哪一步都没卡住，网页不启动', () {
    fakeAsync((async) {
      start();
      async.elapse(const Duration(milliseconds: 1500));
      nativeProgressed();
      async.elapse(const Duration(milliseconds: 1500));
      expect(host.events, isEmpty);
      native.complete(success);
      async.flushMicrotasks();

      expect(outcome, OtpLoginOutcome.nativeSucceeded);
      async.elapse(const Duration(seconds: 30));
      expect(host.events, isEmpty);
    });
  });

  test('原生第一步很快、第二步卡住：从第一步完成起两秒后网页起跑', () {
    fakeAsync((async) {
      start();
      async.elapse(const Duration(milliseconds: 500));
      nativeProgressed();
      async.elapse(const Duration(milliseconds: 1900));
      expect(host.events, isEmpty);
      async.elapse(const Duration(milliseconds: 100));
      expect(host.events, ['open']);

      // 网页起跑以后原生再有进展，不影响已经在跑的网页
      nativeProgressed();
      async.elapse(const Duration(seconds: 5));
      expect(host.events, ['open']);
    });
  });

  test('原生两秒内被告知口令无效：直接结束，网页不启动', () {
    fakeAsync((async) {
      start();
      native.complete(rejected);
      async.flushMicrotasks();

      expect(outcome, OtpLoginOutcome.rejected);
      async.elapse(const Duration(seconds: 30));
      expect(host.events, isEmpty);
    });
  });

  test('原生很快被人机验证拦下：立刻改走网页，并且让用户看见', () {
    fakeAsync((async) {
      final race = start();
      async.elapse(const Duration(milliseconds: 300));
      native.complete(challenged);
      async.flushMicrotasks();

      expect(host.events, ['reveal', 'open']);
      expect(outcome, isNull);

      expect(race.claim(), isTrue);
      host.finish(true);
      async.flushMicrotasks();
      expect(outcome, OtpLoginOutcome.webSucceeded);
    });
  });

  test('原生调用本身抛错：按连不上处理，改走网页', () {
    fakeAsync((async) {
      start();
      native.completeError(StateError('boom'));
      async.flushMicrotasks();

      expect(host.events, ['reveal', 'open']);
    });
  });

  test('原生卡住：两秒后网页在遮罩后面起跑，网页先登录上就取消原生', () {
    fakeAsync((async) {
      final race = start();
      async.elapse(const Duration(milliseconds: 1999));
      expect(host.events, isEmpty);
      async.elapse(const Duration(milliseconds: 1));
      expect(host.events, ['open'], reason: '悄悄起跑，不撤遮罩');

      expect(nativeCancel.isCancelled, isFalse);
      expect(race.claim(), isTrue);
      expect(nativeCancel.isCancelled, isTrue);
      expect(outcome, isNull, reason: '网页还要做登录收口');

      // 被取消的原生请求以失败收场：不算数，也不该动界面
      native.complete(offline);
      async.flushMicrotasks();
      expect(host.events, ['open']);

      host.finish(true);
      async.flushMicrotasks();
      expect(outcome, OtpLoginOutcome.webSucceeded);
    });
  });

  test('网页起跑后原生先换到：撤掉网页，网页不许再往回写', () {
    fakeAsync((async) {
      final race = start();
      async.elapse(const Duration(seconds: 2));
      expect(host.events, ['open']);

      async.elapse(const Duration(seconds: 2));
      native.complete(success);
      async.flushMicrotasks();

      expect(outcome, OtpLoginOutcome.nativeSucceeded);
      expect(host.events, ['open', 'close']);
      expect(race.claim(), isFalse);
    });
  });

  test('网页起跑后原生被告知口令无效：是网页刚用掉的，等网页的结果', () {
    fakeAsync((async) {
      final race = start();
      async.elapse(const Duration(seconds: 2));
      native.complete(rejected);
      async.flushMicrotasks();

      expect(outcome, isNull);
      expect(host.events, ['open'], reason: '网页进行得好好的，不必撤遮罩');

      expect(race.claim(), isTrue);
      host.finish(true);
      async.flushMicrotasks();
      expect(outcome, OtpLoginOutcome.webSucceeded);
    });
  });

  test('网页看到口令无效先收场，原生随后换到：是原生用掉的', () {
    fakeAsync((async) {
      final race = start();
      async.elapse(const Duration(seconds: 2));
      race.reportRejected();
      host.finish(false);
      async.flushMicrotasks();

      expect(outcome, isNull);
      expect(host.events, ['open', 'conceal'], reason: '盖回遮罩接着等原生');

      native.complete(success);
      async.flushMicrotasks();
      expect(outcome, OtpLoginOutcome.nativeSucceeded);
      expect(host.events, ['open', 'conceal'], reason: '网页已经关了，不必再撤');
    });
  });

  test('两边都被告知口令无效：口令确实失效了', () {
    fakeAsync((async) {
      final race = start();
      async.elapse(const Duration(seconds: 2));
      native.complete(rejected);
      async.flushMicrotasks();
      race.reportRejected();
      host.finish(false);
      async.flushMicrotasks();

      expect(outcome, OtpLoginOutcome.rejected);
    });
  });

  test('原生连不上、用户又退出了网页：口令还在，留着下次接着来', () {
    fakeAsync((async) {
      start();
      native.complete(offline);
      async.flushMicrotasks();
      host.finish(null);
      async.flushMicrotasks();

      expect(outcome, OtpLoginOutcome.unfinished);
    });
  });

  test('网页悄悄跑着时原生失败：只剩网页一条路，撤掉遮罩', () {
    fakeAsync((async) {
      start();
      async.elapse(const Duration(seconds: 2));
      native.complete(offline);
      async.flushMicrotasks();

      expect(host.events, ['open', 'reveal']);
      host.finish(null);
      async.flushMicrotasks();
      expect(outcome, OtpLoginOutcome.unfinished);
    });
  });

  test('用户退出网页时原生还没回来：接着等原生', () {
    fakeAsync((async) {
      start();
      async.elapse(const Duration(seconds: 2));
      host.finish(null);
      async.flushMicrotasks();
      expect(outcome, isNull);
      expect(host.events, ['open', 'conceal']);

      native.complete(offline);
      async.flushMicrotasks();
      expect(outcome, OtpLoginOutcome.unfinished);
    });
  });

  test('网页已经登录上、收口前被关掉：口令已用掉，原生也已取消', () {
    fakeAsync((async) {
      final race = start();
      async.elapse(const Duration(seconds: 2));
      expect(race.claim(), isTrue);
      host.finish(null);
      async.flushMicrotasks();

      expect(outcome, OtpLoginOutcome.unfinished);
    });
  });

  test('原生正开着人机验证页：不启动网页，验证结束后再等一个间隔', () {
    fakeAsync((async) {
      start();
      async.elapse(const Duration(seconds: 1));
      verifying = true;
      async.elapse(const Duration(seconds: 20));
      expect(host.events, isEmpty);

      verifying = false;
      async.elapse(const Duration(milliseconds: 500));
      expect(host.events, isEmpty, reason: '验证刚过，原生马上会重放请求');
      async.elapse(const Duration(milliseconds: 1900));
      expect(host.events, isEmpty);
      async.elapse(const Duration(milliseconds: 200));
      expect(host.events, ['open']);
    });
  });

  test('验证通过后原生很快换到：网页始终没启动', () {
    fakeAsync((async) {
      start();
      verifying = true;
      async.elapse(const Duration(seconds: 15));
      verifying = false;
      async.elapse(const Duration(seconds: 1));
      native.complete(success);
      async.flushMicrotasks();

      expect(outcome, OtpLoginOutcome.nativeSucceeded);
      async.elapse(const Duration(seconds: 30));
      expect(host.events, isEmpty);
    });
  });

  test('网页停在要人点的地方：撤掉遮罩', () {
    fakeAsync((async) {
      final race = start();
      async.elapse(const Duration(seconds: 2));
      race.reportNeedsUser();

      expect(host.events, ['open', 'reveal']);
    });
  });

  test('网页悄悄跑了十二秒还没结果：撤掉遮罩，让用户看见', () {
    fakeAsync((async) {
      start();
      async.elapse(const Duration(seconds: 2));
      async.elapse(const Duration(milliseconds: 11900));
      expect(host.events, ['open']);
      async.elapse(const Duration(milliseconds: 100));
      expect(host.events, ['open', 'reveal']);
    });
  });

  test('已经有结果后，迟到的定时器和报告都不再动界面', () {
    fakeAsync((async) {
      final race = start();
      async.elapse(const Duration(seconds: 2));
      native.complete(success);
      async.flushMicrotasks();
      expect(host.events, ['open', 'close']);

      race.reportNeedsUser();
      async.elapse(const Duration(seconds: 60));
      expect(host.events, ['open', 'close']);
      expect(outcome, OtpLoginOutcome.nativeSucceeded);
    });
  });
}

/// 记录竞速让界面做了什么的假宿主
class _Host implements OtpWebLegHost {
  final List<String> events = [];
  Completer<bool?>? _page;

  @override
  Future<bool?> open(OtpWebLeg leg) {
    events.add('open');
    return (_page = Completer<bool?>()).future;
  }

  /// 网页自己关了（true = 完成了登录）
  void finish(bool? result) => _page!.complete(result);

  @override
  void close() {
    events.add('close');
    final page = _page;
    if (page != null && !page.isCompleted) page.complete(null);
  }

  @override
  void reveal() => events.add('reveal');

  @override
  void conceal() => events.add('conceal');
}
