import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/cf_challenge_service.dart';
import 'package:fluxdo/services/network/exceptions/api_exception.dart';
import 'package:fluxdo/services/network/flux_request_spec.dart';
import 'package:fluxdo/services/network/interceptors/request_scheduler_interceptor.dart';

/// CF 验证期间,用户可见请求要排队等结果,而不是一律取消。
///
/// 此前调度器在验证进行中直接取消所有业务请求:用户在验证期间点开的帖子、
/// 发出的回复全部失败,过盾后只能逐个手动重试。改为:
/// - 用户可见请求等这一轮验证的结果,通过后放行,失败才拒绝;
/// - 静默请求(心跳/poll/timings)维持直接取消,避免过盾瞬间集中 flush 触发 429。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late CfChallengeService cf;
  late _CountingAdapter adapter;
  late Dio dio;

  setUp(() {
    cf = CfChallengeService();
    if (cf.isVerifying) cf.debugFinishVerification(false);
    adapter = _CountingAdapter();
    // 用非主站 host,跳过 BrowserTrust 信任门
    dio = Dio(BaseOptions(baseUrl: 'https://scheduler-cf-test.example'))
      ..httpClientAdapter = adapter
      ..interceptors.add(RequestSchedulerInterceptor());
  });

  tearDown(() {
    if (cf.isVerifying) cf.debugFinishVerification(false);
  });

  test('没有进行中的验证时 waitForActiveVerification 立即返回 null', () async {
    expect(
      await cf.waitForActiveVerification(timeout: const Duration(seconds: 1)),
      isNull,
    );
  });

  test('验证期间的用户可见请求等待,验证通过后放行', () async {
    cf.debugBeginVerification();

    final future = dio.get<dynamic>('/t/1.json');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(adapter.callCount, 0, reason: '验证未结束前不应发出');

    cf.debugFinishVerification(true);
    final response = await future;

    expect(response.statusCode, 200);
    expect(adapter.callCount, 1);
  });

  test('验证失败时等待中的请求被拒绝', () async {
    cf.debugBeginVerification();

    final future = dio.get<dynamic>('/t/1.json');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    cf.debugFinishVerification(false);

    await expectLater(
      future,
      throwsA(
        isA<DioException>().having(
          (e) => e.error,
          'error',
          isA<CfChallengeException>(),
        ),
      ),
    );
    expect(adapter.callCount, 0);
  });

  test('静默请求在验证期间仍直接取消', () async {
    cf.debugBeginVerification();

    await expectLater(
      dio.get<dynamic>(
        '/message-bus/poll',
        options: Options(extra: const {FluxRequestKeys.isSilent: true}),
      ),
      throwsA(
        isA<DioException>().having(
          (e) => e.error,
          'error',
          isA<CfChallengeException>(),
        ),
      ),
    );
    expect(adapter.callCount, 0, reason: '静默请求不排队,验证结束后也不会补发');
  });

  test('等待期间请求被取消(如离开页面)时立即结束等待', () async {
    cf.debugBeginVerification();
    final cancelToken = CancelToken();

    final future = dio.get<dynamic>('/t/1.json', cancelToken: cancelToken);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    cancelToken.cancel('left page');

    await expectLater(
      future,
      throwsA(
        isA<DioException>().having(
          (e) => e.type,
          'type',
          DioExceptionType.cancel,
        ),
      ),
    );
    expect(adapter.callCount, 0);
    expect(cf.isVerifying, isTrue, reason: '取消单个请求不影响验证本身');
  });
}

class _CountingAdapter implements HttpClientAdapter {
  int callCount = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    callCount++;
    return ResponseBody.fromString(
      '{"ok":true}',
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
