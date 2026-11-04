import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/services/local_notification_service.dart'
    show navigatorKey;
import 'package:fluxdo/services/network/doh_proxy/gateway_error.dart';
import 'package:fluxdo/services/startup_progress.dart';
import 'package:fluxdo/utils/error_utils.dart';

final _options = RequestOptions(path: 'https://linux.do/latest.json');

DioException _unknown(Object inner) => DioException(
  requestOptions: _options,
  type: DioExceptionType.unknown,
  error: inner,
);

DioException _bad(int status, {bool gateway = false, Object? data}) =>
    DioException(
      requestOptions: _options,
      type: DioExceptionType.badResponse,
      response: Response<dynamic>(
        requestOptions: _options,
        statusCode: status,
        data: data,
        headers: Headers.fromMap({
          if (gateway) GatewayError.header: ['1'],
        }),
      ),
    );

/// S.current 要从导航器拿 context：挂一个最小的中文 MaterialApp
Future<void> _pumpApp(WidgetTester tester) => tester.pumpWidget(
  TranslationProvider(
    child: MaterialApp(
      navigatorKey: navigatorKey,
      locale: const Locale('zh'),
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocaleUtils.supportedLocales,
      home: const SizedBox(),
    ),
  ),
);

void main() {
  group('证书 / 握手错误分类', () {
    testWidgets('WebView 的 SSL 协议错误按网络错误报，不叫证书异常', (tester) async {
      await _pumpApp(tester);
      final info = ErrorUtils.getErrorInfo(
        _unknown(Exception('net::ERR_SSL_PROTOCOL_ERROR')),
      );
      expect(info.title, isNot(S.current.error_certificateError));
      expect(info.title, S.current.error_networkUnavailable);
    });

    testWidgets('握手中途被掐按网络错误报', (tester) async {
      await _pumpApp(tester);
      final info = ErrorUtils.getErrorInfo(
        _unknown(
          Exception(
            'HandshakeException: Connection terminated during handshake',
          ),
        ),
      );
      expect(info.title, S.current.error_networkUnavailable);
    });

    testWidgets('证书校验失败仍报证书异常', (tester) async {
      await _pumpApp(tester);
      for (final text in [
        'HandshakeException: Handshake error in client (OS Error: CERTIFICATE_VERIFY_FAILED)',
        'net::ERR_CERT_AUTHORITY_INVALID',
      ]) {
        final info = ErrorUtils.getErrorInfo(_unknown(Exception(text)));
        expect(info.title, S.current.error_certificateError, reason: text);
      }
    });
  });

  group('网关错误', () {
    testWidgets('带网关头的 502 认作连不上上游，正文进日志', (tester) async {
      await _pumpApp(tester);
      final error = _bad(502, gateway: true, data: 'Connection timeout');
      expect(GatewayError.isUpstreamFailure(error), isTrue);
      expect(GatewayError.textOf(error.response), 'Connection timeout');
      expect(
        describeStartupFailure(error),
        S.current.preheat_detailUpstreamUnreachable,
      );
    });

    testWidgets('网关 502 的报错页说连不上服务器，不说服务暂不可用', (tester) async {
      await _pumpApp(tester);
      final info = ErrorUtils.getErrorInfo(
        _bad(502, gateway: true, data: 'Connect failed: Connection timeout'),
      );
      expect(info.title, S.current.error_upstreamUnreachable);
      expect(info.isNetworkError, isTrue);
    });

    testWidgets('源站自己回的 502 不算网关错误', (tester) async {
      await _pumpApp(tester);
      final error = _bad(502, data: '<html>Bad gateway</html>');
      expect(GatewayError.isUpstreamFailure(error), isFalse);
      expect(GatewayError.textOf(error.response), isNull);
      expect(describeStartupFailure(error), S.current.preheat_detailHttp(502));
    });

    testWidgets('流式响应的正文读不到时用头里的原因，老网关头值 "1" 时只报 gateway error', (
      tester,
    ) async {
      await _pumpApp(tester);
      final streamed = DioException(
        requestOptions: _options,
        type: DioExceptionType.badResponse,
        response: Response<dynamic>(
          requestOptions: _options,
          statusCode: 502,
          data: ResponseBody.fromString('Connect failed', 502),
          headers: Headers.fromMap({
            GatewayError.header: ['Connect failed: Connection refused'],
          }),
        ),
      );
      expect(
        GatewayError.textOf(streamed.response),
        'Connect failed: Connection refused',
      );
      final legacy = DioException(
        requestOptions: _options,
        type: DioExceptionType.badResponse,
        response: Response<dynamic>(
          requestOptions: _options,
          statusCode: 502,
          data: ResponseBody.fromString('Connect failed', 502),
          headers: Headers.fromMap({
            GatewayError.header: ['1'],
          }),
        ),
      );
      expect(GatewayError.textOf(legacy.response), 'gateway error');
    });

    testWidgets('网关错误正文过长时截断', (tester) async {
      await _pumpApp(tester);
      final error = _bad(502, gateway: true, data: 'x' * 1000);
      expect(GatewayError.textOf(error.response), hasLength(300));
    });
  });
}
