import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/log/log_writer.dart';
import 'package:fluxdo/services/network/interceptors/network_log_interceptor.dart';

/// 网络日志的 `duration` 只算最后一次真正发出去的那一段；排队和被重放掉的前几次
/// 另记在 `totalMs` 里。2026-11-20 排查卡顿：上游连接断掉后用户等了 25 s，日志里
/// 那条请求只有 215 ms
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('request_total_ms_test');
    await LogWriter.resetForTesting();
    await LogWriter.initForTesting(tempDir);
  });

  tearDown(() async {
    await LogWriter.resetForTesting();
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  test('发出前排了队：duration 不含排队，totalMs 含', () async {
    final dio = _buildDio(queueWait: const Duration(milliseconds: 700));
    await dio.get<dynamic>('/latest.json');

    final entry = await _readSingleRequestEntry();
    expect(entry['duration'] as int, lessThan(500));
    expect(entry['totalMs'] as int, greaterThanOrEqualTo(700));
  });

  test('没排队也没重放：不记 totalMs', () async {
    final dio = _buildDio(queueWait: Duration.zero);
    await dio.get<dynamic>('/latest.json');

    final entry = await _readSingleRequestEntry();
    expect(entry.containsKey('totalMs'), isFalse);
  });

  test('重放沿用第一次发起的时刻', () async {
    final options = RequestOptions(path: '/latest.json');
    NetworkLogInterceptor.markFirstSeen(options);
    final first = options.extra.values.single as int;
    await Future<void>.delayed(const Duration(milliseconds: 20));
    NetworkLogInterceptor.markFirstSeen(options);
    expect(options.extra.values.single, first);
  });
}

Dio _buildDio({required Duration queueWait}) {
  final dio = Dio(BaseOptions(baseUrl: 'https://linux.do'))
    ..httpClientAdapter = _OkAdapter();
  // 与 DiscourseDio 一样：链首记发起时刻，中间是会让请求等的拦截器，日志在链尾
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        NetworkLogInterceptor.markFirstSeen(options);
        handler.next(options);
      },
    ),
  );
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) async {
        if (queueWait > Duration.zero) await Future<void>.delayed(queueWait);
        handler.next(options);
      },
    ),
  );
  dio.interceptors.add(NetworkLogInterceptor());
  return dio;
}

Future<Map<String, dynamic>> _readSingleRequestEntry() async {
  await LogWriter.instance.flushNow();
  final file = await LogWriter.getLogFile();
  final entries = file
      .readAsLinesSync()
      .where((line) => line.trim().isNotEmpty)
      .map((line) => jsonDecode(line) as Map<String, dynamic>)
      .where((e) => e['type'] == 'request')
      .toList();
  expect(entries, hasLength(1));
  return entries.single;
}

class _OkAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
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
