import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/network/discourse_dio.dart';
import 'package:fluxdo/services/network/flux_request_spec.dart';

/// 请求旁观者契约：恢复层决定重放时通知挂在请求上的旁观者。
///
/// 以前 Dio 工厂按 `requestTag == 'preload-home'` 直接写启动页；现在网络层
/// 只认 [FluxRequestObserver]，谁挂谁收，不挂的请求完全不受影响。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('瞬态重试按次序通知请求上的旁观者，带上一轮的失败', () async {
    final dio = DiscourseDio.create(
      kind: DiscourseDioKind.download,
      enableCookies: false,
    );
    final adapter = _FlakyAdapter(failuresBeforeSuccess: 2);
    dio.httpClientAdapter = adapter;
    final observer = _RecordingObserver();

    final response = await dio.get<String>(
      'https://example.com/flaky',
      options: Options(extra: {FluxRequestKeys.observer: observer}),
    );

    expect(response.statusCode, 200);
    expect(observer.retries, [1, 2]);
    expect(observer.retryStatuses, [502, 502]);
    expect(observer.challenges, isEmpty);
  });

  test('没挂旁观者的请求照常重试', () async {
    final dio = DiscourseDio.create(
      kind: DiscourseDioKind.download,
      enableCookies: false,
    );
    final adapter = _FlakyAdapter(failuresBeforeSuccess: 1);
    dio.httpClientAdapter = adapter;

    final response = await dio.get<String>('https://example.com/flaky');

    expect(response.statusCode, 200);
    expect(adapter.calls, 2);
  });

  test('extra 里不是旁观者的值被忽略', () {
    final spec = FluxRequestSpec({FluxRequestKeys.observer: 'not-an-observer'});
    expect(spec.observer, isNull);
    final observer = _RecordingObserver();
    expect(
      FluxRequestSpec({FluxRequestKeys.observer: observer}).observer,
      same(observer),
    );
  });
}

class _RecordingObserver implements FluxRequestObserver {
  final retries = <int>[];
  final retryStatuses = <int?>[];
  final challenges = <int?>[];

  @override
  void onRetry(int attempt, DioException error) {
    retries.add(attempt);
    retryStatuses.add(error.response?.statusCode);
  }

  @override
  void onCfChallenge(int? statusCode) => challenges.add(statusCode);
}

class _FlakyAdapter implements HttpClientAdapter {
  _FlakyAdapter({required this.failuresBeforeSuccess});

  final int failuresBeforeSuccess;
  int calls = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls++;
    if (calls <= failuresBeforeSuccess) {
      return ResponseBody.fromString('bad gateway', 502);
    }
    return ResponseBody.fromString('ok', 200);
  }

  @override
  void close({bool force = false}) {}
}
