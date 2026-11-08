import 'dart:async';

import 'package:dio/dio.dart';

import '../flux_request_spec.dart';

/// 手动跟随重定向，让 Cookie 管理器按目标 URL 重新选取 Cookie。
///
/// 移植自上游 eac274bd（去掉了只属于其网络核心的连接元数据）：
/// - 303 与 301/302 的 POST 按 RFC 9110 转 GET 并清掉实体头，307/308 原样重放；
///   一次性 Stream 请求体不能重放，直接报错而不是静默发空请求；
/// - 跨源跳转去掉授权、CSRF、User-Api-Key、Origin/Referer 等源站头，并禁止
///   请求头拦截器给下一跳重新注入 CSRF；Cookie 仍由 Cookie 管理器按目标 URL 重取；
/// - 用完整 RequestOptions 发下一跳，保留取消令牌、超时、进度回调和 validateStatus；
/// - 跳转响应体只对已知 ≤8 KiB 的有限排空（最多 100 ms），其余立即取消。
class RedirectInterceptor extends Interceptor {
  RedirectInterceptor(this._dio);

  final Dio _dio;
  static const hopsKey = 'redirectHops';
  static const _startKey = '_redirectStart';
  static const _countKey = '_redirectCount';
  static const _maxRedirects = 10;

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    options.extra[_startKey] = Stopwatch()..start();
    handler.next(options);
  }

  @override
  Future<void> onResponse(
    Response response,
    ResponseInterceptorHandler handler,
  ) async {
    final original = response.requestOptions;
    final status = response.statusCode;
    if (original.spec.skipRedirect ||
        !const [301, 302, 303, 307, 308].contains(status)) {
      return handler.next(response);
    }

    var bodyReleased = false;
    try {
      final location = response.headers.value('location');
      if (location == null) return handler.next(response);

      // 小响应体限时读完以保留 H1 连接，其余直接取消，避免阻塞下一跳。
      bodyReleased = true;
      await _discardBody(response);
      final count = original.extra[_countKey] as int? ?? 0;
      final limit = original.maxRedirects < _maxRedirects
          ? original.maxRedirects
          : _maxRedirects;
      if (count >= limit) throw StateError('重定向次数超过上限 $limit');
      final target = original.uri.resolve(location);
      if (!const ['http', 'https'].contains(target.scheme) ||
          target.host.isEmpty ||
          target.userInfo.isNotEmpty) {
        throw StateError('无效的 HTTP 重定向目标');
      }

      final method = original.method.toUpperCase();
      final switchToGet =
          (status == 303 && method != 'HEAD') ||
          ((status == 301 || status == 302) && method == 'POST');
      var data = switchToGet ? null : original.data;
      // 一次性流不能安全重放；不缓存整个上传以换取重试能力。
      if (data is Stream) throw StateError('无法重放流式请求体以跟随重定向');
      if (data is FormData) data = data.clone();

      final crossOrigin = original.uri.origin != target.origin;
      final headers = Map<String, dynamic>.from(original.headers)
        ..removeWhere((key, _) {
          final name = key.toLowerCase();
          return name == 'cookie' ||
              name == 'host' ||
              (switchToGet && _bodyHeaders.contains(name)) ||
              (crossOrigin && _originHeaders.contains(name));
        });
      final hop = <String, dynamic>{
        'host': original.uri.host,
        'targetHost': target.host,
        'status': status,
        'method': method,
        'elapsedMs':
            (original.extra[_startKey] as Stopwatch?)?.elapsedMilliseconds,
        'httpVersion': response.extra[HttpClientAdapter.extraKeyHttpVersion],
      };
      final extra = Map<String, dynamic>.from(original.extra)
        // 当前原请求仍占用调度槽位。内部重定向必须绕过调度器，否则并发槽
        // 和速率窗口会被重定向链自己耗尽，外层响应也无法完成释放。
        ..[FluxRequestKeys.skipScheduler] = true
        ..[_countKey] = count + 1
        ..[hopsKey] = <Map<String, dynamic>>[
          ...?original.extra[hopsKey] as List<Map<String, dynamic>>?,
          hop,
        ];
      // 防止后续请求头拦截器把源站凭据再次注入跨源请求。
      if (crossOrigin) extra[FluxRequestKeys.skipCsrf] = true;
      final next = original.copyWith(
        path: target.toString(),
        queryParameters: {}, // Location 已完整解析，不能重复拼接原查询参数。
        method: switchToGet ? 'GET' : method,
        headers: headers,
        extra: extra,
      )..data = data; // copyWith(data: null) 会保留旧 data，必须显式清空。
      if (switchToGet) {
        next.headers.removeWhere(
          (key, _) => _bodyHeaders.contains(key.toLowerCase()),
        );
        next.onSendProgress = null;
      }
      if (original.cancelToken?.isCancelled ?? false) {
        throw original.cancelToken!.cancelError!;
      }
      handler.resolve(await _dio.fetch<dynamic>(next));
    } catch (error, stack) {
      if (!bodyReleased) await _discardBody(response);
      if (error is DioException) {
        handler.reject(error);
      } else {
        handler.reject(
          DioException(
            requestOptions: original,
            response: response,
            type: DioExceptionType.badResponse,
            error: error,
            stackTrace: stack,
          ),
        );
      }
    }
  }

  static const _bodyHeaders = {
    'content-length',
    'content-type',
    'content-encoding',
    'transfer-encoding',
    'content-language',
    'content-location',
    'digest',
  };
  static const _originHeaders = {
    'authorization',
    'proxy-authorization',
    'x-csrf-token',
    'user-api-key',
    'api-key',
    'api-username',
    'origin',
    'referer',
    'x-requested-with',
    'sec-fetch-site',
    'sec-fetch-mode',
    'sec-fetch-dest',
    'discourse-present',
  };

  static Future<void> _discardBody(Response response) async {
    final body = response.data;
    if (body is! ResponseBody) return;
    const maxDrainBytes = 8 * 1024;
    final length = int.tryParse(
      body.headers[Headers.contentLengthHeader]?.firstOrNull ?? '',
    );
    if (length == null || length < 0 || length > maxDrainBytes) {
      await body.stream
          .listen((_) {}, onError: (Object _, StackTrace _) {})
          .cancel();
      return;
    }
    // 参考 Go/OkHttp 的有限排空：只丢弃小响应，不分配整段缓存。
    // 不信任声明长度；实际字节和等待时间都受限，防止慢/大响应拖住图片。
    final done = Completer<void>();
    var bytes = 0;
    late StreamSubscription<List<int>> subscription;
    void finish() {
      if (!done.isCompleted) done.complete();
    }

    subscription = body.stream.listen(
      (chunk) {
        bytes += chunk.length;
        if (bytes > maxDrainBytes) finish();
      },
      onDone: finish,
      onError: (Object _, StackTrace _) => finish(),
    );
    final timer = Timer(const Duration(milliseconds: 100), finish);
    try {
      await done.future;
    } finally {
      timer.cancel();
      await subscription.cancel();
    }
  }
}
