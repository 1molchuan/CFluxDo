import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/constants.dart';
import 'package:fluxdo/services/network/background_gate.dart';
import 'package:fluxdo/services/network/interceptors/request_scheduler_interceptor.dart';
import 'package:fluxdo/services/network/request_scheduler_config.dart';

class _Adapter implements HttpClientAdapter {
  _Adapter({this.status = 200, this.headers = const {}});

  final int status;
  final Map<String, List<String>> headers;
  int calls = 0;
  final paths = <String>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls++;
    paths.add(options.path);
    return ResponseBody.fromString('{}', status, headers: headers);
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('并发为零但速率窗口已满时，排队请求在窗口到期后自动发出', () async {
    final oldConcurrent = RequestSchedulerConfig.maxConcurrent;
    final oldMax = RequestSchedulerConfig.maxPerWindow;
    final oldSeconds = RequestSchedulerConfig.windowSeconds;
    RequestSchedulerConfig.maxConcurrent = 3;
    RequestSchedulerConfig.maxPerWindow = 1;
    RequestSchedulerConfig.windowSeconds = 1;
    final adapter = _Adapter();
    final dio = Dio(BaseOptions(baseUrl: 'https://scheduler-idle.test'))
      ..httpClientAdapter = adapter
      ..interceptors.add(RequestSchedulerInterceptor());
    addTearDown(() {
      dio.close(force: true);
      RequestSchedulerConfig.maxConcurrent = oldConcurrent;
      RequestSchedulerConfig.maxPerWindow = oldMax;
      RequestSchedulerConfig.windowSeconds = oldSeconds;
    });

    // 首个请求已经完成：没有在途请求再触发 _release。
    await dio.get('/chat/api/channels/2/messages');
    expect(adapter.calls, 1);
    final second = dio.get('/chat/api/channels/2/messages');
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(adapter.calls, 1);
    final response = await second.timeout(const Duration(seconds: 3));
    expect(response.statusCode, 200);
    expect(adapter.calls, 2);
  });

  group('后台让路', () {
    final sleeps = <Duration>[];
    setUp(() {
      sleeps.clear();
      BackgroundGate.instance.resetForTest(delay: (d) async => sleeps.add(d));
    });
    tearDown(() => BackgroundGate.instance.resetForTest());

    test('前台请求之后紧跟的后台请求先让 3 秒以内，再发出', () async {
      final adapter = _Adapter();
      final dio = Dio(BaseOptions(baseUrl: 'https://scheduler-yield.test'))
        ..httpClientAdapter = adapter
        ..interceptors.add(RequestSchedulerInterceptor());
      addTearDown(() => dio.close(force: true));

      await dio.get('/latest.json');
      expect(sleeps, isEmpty, reason: '前台请求不等');
      await dio.post(
        '/topics/timings',
        options: Options(extra: const {'isSilent': true}),
      );
      expect(adapter.paths, ['/latest.json', '/topics/timings']);
      expect(sleeps, isNotEmpty);
      expect(
        sleeps.first <= BackgroundGate.foregroundYield &&
            sleeps.first > const Duration(seconds: 2),
        isTrue,
        reason: '${sleeps.first}',
      );
    });

    test('主站的限流 429 让后台请求一起退避，CF 挑战型 429 不算', () async {
      final host = Uri.parse(AppConstants.baseUrl).host;
      final limited = _Adapter(
        status: 429,
        headers: {
          'retry-after': ['20'],
        },
      );
      final dio = Dio(BaseOptions(baseUrl: 'https://$host'))
        ..httpClientAdapter = limited
        ..interceptors.add(RequestSchedulerInterceptor());
      addTearDown(() => dio.close(force: true));
      await expectLater(dio.get('/latest.json'), throwsA(isA<DioException>()));
      expect(
        BackgroundGate.instance.backoffRemaining > const Duration(seconds: 15),
        isTrue,
      );

      BackgroundGate.instance.resetForTest(delay: (d) async => sleeps.add(d));
      final challenged = _Adapter(
        status: 429,
        headers: {
          'cf-mitigated': ['challenge'],
        },
      );
      dio.httpClientAdapter = challenged;
      await expectLater(dio.get('/latest.json'), throwsA(isA<DioException>()));
      expect(BackgroundGate.instance.backoffRemaining, Duration.zero);
    });

    test('别的站点的 429 不影响主站后台请求', () async {
      final dio = Dio(BaseOptions(baseUrl: 'https://credit.example.test'))
        ..httpClientAdapter = _Adapter(status: 429)
        ..interceptors.add(RequestSchedulerInterceptor());
      addTearDown(() => dio.close(force: true));
      await expectLater(dio.get('/api/x'), throwsA(isA<DioException>()));
      expect(BackgroundGate.instance.backoffRemaining, Duration.zero);
    });
  });
}
