import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/network/discourse_dio.dart';
import 'package:fluxdo/services/startup/app_startup.dart';

import 'app_startup_fakes.dart';

/// 离线冷启动、网络恢复时连接被切断的回归测试。
///
/// 真机时间线（模拟器 logcat，2026-10-15）新旧两版完全一致：
/// - 直连预加载 4 次（首发 + 1 / 2 / 4 s 退避），本地网关每次都回 502
///   （Network is unreachable）；
/// - 启动期 WebView 约 15 s 后销毁，1.2 s 后回退直连；
/// - 这时网络刚恢复（先连上蜂窝）：回退请求的上游连接已建好，约 1.6 s 后
///   系统切到 Wi-Fi、销毁蜂窝上的 socket（Netd "Destroyed 1 sockets"），
///   请求被掐断 → dart:io HttpException（DioException.unknown）。
///
/// 这类错误以前不算瞬态、不重放，预加载直接失败、落到「重试连接」错误页；
/// 1.1.1-beta.2 那次是回退请求恰好比切网早 0.35 s 收完响应。现在它与连接
/// 失败一样按 1 s 退避重放，切网后的那次重放走 Wi-Fi 成功，启动自动继续。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    '离线期间直连按原节奏重试并失败，回退请求被切网掐断后重放成功：不用点重试就进到会话判定',
    () async {
      final adapter = _TimelineAdapter([
        // 直连：离线，本地网关回 502（与旧版相同：首发 + 3 次退避）
        _Step.offline,
        _Step.offline,
        _Step.offline,
        _Step.offline,
        // 回退直连：网络刚恢复，蜂窝 → Wi-Fi 切换掐断连接
        _Step.droppedByHandover,
        // 1 s 后重放：走 Wi-Fi，成功
        _Step.ok,
      ]);
      final dio = DiscourseDio.create(
        kind: DiscourseDioKind.api,
        enableCookies: false,
      )..httpClientAdapter = adapter;

      final ports = FakeStartupPorts(preloadedUser: aliceJson)
        ..preloadBody = () async {
          // 与 BrowserTrust 的预加载同构：直连失败 → （启动期 WebView，此处
          // 不参与）→ 回退直连，回退再失败才是终局失败
          try {
            await dio.get<String>('https://linux.do/');
            fail('离线时直连不应成功');
          } on DioException catch (e) {
            expect(e.response?.statusCode, 502);
          }
          await dio.get<String>('https://linux.do/');
        };
      final startup = AppStartup(ports: ports)
        ..registerPostLogin(FakePostLoginStart(ports.log));
      startup.storesReady();
      startup.launch();

      // 启动页只等 ensurePreloaded：不会以错误结束
      await startup.ensurePreloaded(reason: 'preheat_gate');
      await Future<void>.delayed(Duration.zero);

      // 没有任何用户操作就走到了会话判定与登录后启动项
      expect(ports.log, isNot(contains('preload:failed')));
      expect(startup.isLoggedIn, isTrue);
      expect(startup.verdictNow?.user?.username, 'alice');
      expect(ports.log, contains('message_bus:start'));
      expect(ports.log.where((e) => e == 'preload'), hasLength(1));

      // 尝试次数与节奏：直连 4 次（间隔 1 / 2 / 4 s，与旧版一致），回退 2 次
      // （被掐断后 1 s 重放）
      expect(adapter.calls, hasLength(6));
      final gaps = <double>[
        for (var i = 1; i < adapter.calls.length; i++)
          adapter.calls[i].difference(adapter.calls[i - 1]).inMilliseconds /
              1000,
      ];
      expect(gaps[0], closeTo(1, 0.5));
      expect(gaps[1], closeTo(2, 0.5));
      expect(gaps[2], closeTo(4, 0.5));
      // gaps[3] 是直连失败到回退直连之间（真机上是 WebView 阶段），不约束
      expect(gaps[4], closeTo(1, 0.5));
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test('网络一直不回来：回退直连按原节奏重试后失败，错误页照旧出现', () async {
    final adapter = _TimelineAdapter([_Step.offline]);
    final dio = DiscourseDio.create(
      kind: DiscourseDioKind.api,
      enableCookies: false,
    )..httpClientAdapter = adapter;
    final ports = FakeStartupPorts(preloadedUser: aliceJson)
      ..preloadBody = () => dio.get<String>('https://linux.do/');
    final startup = AppStartup(ports: ports);
    startup.storesReady();
    startup.launch();

    await expectLater(
      startup.ensurePreloaded(reason: 'preheat_gate'),
      throwsA(isA<DioException>()),
    );
    expect(adapter.calls, hasLength(4), reason: '首发 + 3 次退避，与旧版相同');
    expect(startup.verdictNow, isNull);
    expect(ports.log, contains('preload:failed'));
  }, timeout: const Timeout(Duration(seconds: 60)));
}

enum _Step { offline, droppedByHandover, ok }

/// 按脚本逐次回应，并记下每次请求到达的时刻。
class _TimelineAdapter implements HttpClientAdapter {
  _TimelineAdapter(this._steps);

  final List<_Step> _steps;
  final List<DateTime> calls = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final step = _steps[calls.length.clamp(0, _steps.length - 1)];
    calls.add(DateTime.now());
    switch (step) {
      case _Step.offline:
        // 本地网关连不上上游：502
        return ResponseBody.fromString('Bad Gateway', 502);
      case _Step.droppedByHandover:
        // dart:io 在收到响应头之前连接被关闭
        throw const HttpException(
          'Connection closed before full header was received',
        );
      case _Step.ok:
        return ResponseBody.fromString(
          '<html><body>home</body></html>',
          200,
          headers: {
            Headers.contentTypeHeader: const ['text/html'],
          },
        );
    }
  }

  @override
  void close({bool force = false}) {}
}
