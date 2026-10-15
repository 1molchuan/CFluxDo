import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/network/cookie/app_cookie_manager.dart';
import 'package:fluxdo/services/network/cookie/cookie_jar_service.dart';
import 'package:fluxdo/services/network/discourse_dio.dart';
import 'package:fluxdo/services/network/recovery/recovery_coordinator.dart';
import 'package:fluxdo/services/network/recovery/session_heal_policy.dart';

/// Dio 工厂与 jar 初始化顺序的契约。
///
/// 以前 jar 没就绪时工厂会**静默**少装 AppCookieManager 与会话自愈，这个
/// Dio 一辈子不带 cookie。现在要么链路完整（等 jar），要么根本不建。
///
/// 注意：CookieJarService 是单例，本文件依赖「第一个测试运行时 jar 尚未
/// 初始化」，测试顺序不能打乱。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('jar 未就绪时建出的 Dio 仍装上 Cookie 管理与会话自愈，请求等 jar 就绪后带上 cookie', () async {
    final jarService = CookieJarService();
    expect(jarService.isInitialized, isFalse, reason: '前提：jar 还没初始化');

    final dio = DiscourseDio.create(kind: DiscourseDioKind.download);
    final adapter = _RecordingAdapter();
    dio.httpClientAdapter = adapter;

    // 拦截器没有被悄悄丢掉
    final cookieManagers = dio.interceptors.whereType<JarReadyCookieManager>();
    expect(cookieManagers, hasLength(1));
    final recovery = dio.interceptors.whereType<RecoveryCoordinator>().single;
    expect(recovery.policies.whereType<SessionSelfHealPolicy>(), hasLength(1));

    // 恢复协调器仍排在 Cookie 管理之前（自愈要读 Set-Cookie 落库前的快照）
    final list = dio.interceptors.toList();
    expect(
      list.indexOf(recovery),
      lessThan(list.indexOf(cookieManagers.single)),
    );

    // 第一个请求自己触发 jar 初始化，同时启动批次也在初始化：共用一次，
    // 只建一个 jar（以前并发初始化会建两个，第二个还撞 late final 重复赋值）
    final firstRequest = dio.get<String>('https://linux.do/latest.json');
    await Future.wait([jarService.initialize(), jarService.initialize()]);
    final jar = jarService.cookieJar;
    await firstRequest;
    expect(identical(jarService.cookieJar, jar), isTrue);

    // jar 就绪后写入的 cookie 会带在之后的请求上
    await jar.saveFromResponse(Uri.parse('https://linux.do/'), [
      Cookie('probe_cookie', 'v1')..path = '/',
    ]);
    await dio.get<String>('https://linux.do/latest.json');
    expect(adapter.lastCookieHeader, contains('probe_cookie=v1'));
  });

  test('jar 已就绪时照旧直接装 AppCookieManager', () async {
    await CookieJarService().initialize();
    final dio = DiscourseDio.create(kind: DiscourseDioKind.download);
    expect(dio.interceptors.whereType<AppCookieManager>(), hasLength(1));
    expect(dio.interceptors.whereType<JarReadyCookieManager>(), isEmpty);
    final recovery = dio.interceptors.whereType<RecoveryCoordinator>().single;
    expect(recovery.policies.whereType<SessionSelfHealPolicy>(), hasLength(1));
  });

  test('enableCookies: false 才不装 Cookie 管理与会话自愈', () async {
    final dio = DiscourseDio.create(
      kind: DiscourseDioKind.download,
      enableCookies: false,
    );
    expect(dio.interceptors.whereType<AppCookieManager>(), isEmpty);
    expect(dio.interceptors.whereType<JarReadyCookieManager>(), isEmpty);
    final recovery = dio.interceptors.whereType<RecoveryCoordinator>().single;
    expect(recovery.policies.whereType<SessionSelfHealPolicy>(), isEmpty);
  });
}

class _RecordingAdapter implements HttpClientAdapter {
  String? lastCookieHeader;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    lastCookieHeader = options.headers[HttpHeaders.cookieHeader]?.toString();
    return ResponseBody.fromString(
      '{}',
      200,
      headers: {
        Headers.contentTypeHeader: const ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
