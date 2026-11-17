import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/models/cdk_project.dart';
import 'package:fluxdo/services/cdk_api_service.dart';
import 'package:fluxdo/services/network/exceptions/oauth_exception.dart';
import 'package:fluxdo/utils/link_launcher.dart';
import 'package:fluxdo/widgets/cdk/hcaptcha_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Adapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  int status = 200;
  Object body = const {'error_msg': '', 'data': null};

  @override
  Future<ResponseBody> fetch(
    RequestOptions request,
    Stream<Uint8List>? stream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(request);
    return ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

const _key = '0f1e2d3c-4b5a-6978-8a9b-acbdcedfe0f1';

void main() {
  group('CDK 模型', () {
    test('项目详情：剩余、价格、分发方式、时间转本地', () {
      final p = CdkProject.fromJson({
        'id': 'abc',
        'name': '测试项目',
        'description': '说明',
        'distribution_type': 0,
        'total_items': 10,
        'available_items_count': 3,
        'start_time': '2026-11-15T12:00:00+08:00',
        'end_time': '2026-11-20T12:00:00Z',
        'minimum_trust_level': 2,
        'allow_same_ip': false,
        'risk_level': 80,
        'price': '1.50',
        'creator_username': 'u',
        'creator_nickname': '',
        'tags': ['游戏'],
        'is_received': false,
        'received_content': '',
      });
      expect(p.distributionType, CdkDistributionType.oneForEach);
      expect(p.isPaid, isTrue);
      expect(p.receivedCount, 7);
      expect(p.startTime!.isUtc, isFalse);
      expect(p.startTime!.toUtc(), DateTime.utc(2026, 11, 15, 4));
      final received = p.copyWithReceived('CODE-1');
      expect(received.isReceived, isTrue);
      expect(received.availableItems, 2);
      expect(received.receivedContent, 'CODE-1');
    });

    test('免费项目与缺字段不崩', () {
      final p = CdkProject.fromJson({'id': 1, 'price': '0', 'tags': null});
      expect(p.id, '1');
      expect(p.isPaid, isFalse);
      expect(p.tags, isEmpty);
      expect(p.distributionType, CdkDistributionType.oneForEach);
    });

    test('领取结果：免费给 itemContent，付费给 pay_url', () {
      final free = CdkReceiveResult.fromJson({'itemContent': 'K'});
      expect(free.itemContent, 'K');
      expect(free.requirePayment, isFalse);
      final paid = CdkReceiveResult.fromJson({
        'require_payment': true,
        'pay_url': 'https://credit.linux.do/epay/pay/x',
        'amount': '2.00',
      });
      expect(paid.requirePayment, isTrue);
      expect(paid.payUrl, startsWith('https://credit.linux.do/'));
    });

    test('领取记录分页', () {
      final page = CdkReceivedPage.fromJson({
        'total': 21,
        'results': [
          {
            'project_id': 'p',
            'project_name': 'n',
            'project_creator': 'c',
            'project_creator_nickname': '',
            'content': 'X',
            'received_at': null,
          },
          'garbage',
        ],
      });
      expect(page.total, 21);
      expect(page.items, hasLength(1));
      expect(page.items.single.receivedAt, isNull);
    });
  });

  group('hCaptcha sitekey 识别', () {
    test('压缩脚本里 sitekey 紧挨着的 uuid', () {
      const script =
          'x.jsx)(h.Z,{sitekey:t||"$_key",size:"invisible",theme:"light"})';
      expect(CdkApiService.extractSiteKey(script), _key);
    });

    test('只提到 hcaptcha 且只有一个 uuid 时取它；多个就不猜', () {
      const one = 'import("hcaptcha");var k="$_key";';
      expect(CdkApiService.extractSiteKey(one), _key);
      const two = 'hcaptcha;"$_key";"11111111-2222-3333-4444-555555555555"';
      expect(CdkApiService.extractSiteKey(two), isNull);
      expect(CdkApiService.extractSiteKey('var k="$_key"'), isNull);
    });

    test('领取页自己的脚本排在最前（含 RSC 数据里不带 /_next/ 的引用）', () {
      // 2026-11-17 线上形态：页面脚本写在 self.__next_f.push 的转义字符串里
      const html =
          '<script src="/_next/static/chunks/webpack-1.js"></script>'
          '<script src="/_next/static/chunks/app/layout-2.js"></script>'
          r'<script>self.__next_f.push([1,"2:I[\"static/chunks/app/(main)/receive/%5BprojectId%5D/page-9.js\"]"])</script>';
      final paths = CdkApiService.scriptPaths(html);
      expect(
        paths.first,
        '/_next/static/chunks/app/(main)/receive/%5BprojectId%5D/page-9.js',
      );
      expect(paths, hasLength(3));
      expect(paths.every((p) => p.startsWith('/_next/static/chunks/')), isTrue);
    });

    test('线上领取页脚本的 sitekey 写法', () {
      const script =
          'children:[(0,s.jsx)(eo.A,{sitekey:a||"$_key",size:"invisible"';
      expect(CdkApiService.extractSiteKey(script), _key);
    });

    test('isSiteKey 只认完整 uuid', () {
      expect(CdkApiService.isSiteKey(_key), isTrue);
      expect(CdkApiService.isSiteKey('x$_key'), isFalse);
    });
  });

  group('cdk.linux.do 链接路由', () {
    test('领取链接、首页、记录走原生，其它不接', () {
      expect(
        cdkLinkTarget('https://cdk.linux.do/receive/AbC-1')?.projectId,
        'AbC-1',
      );
      expect(cdkLinkTarget('https://cdk.linux.do/'), isNotNull);
      expect(
        cdkLinkTarget('https://cdk.linux.do/dashboard')?.projectId,
        isNull,
      );
      expect(cdkLinkTarget('https://cdk.linux.do/received'), isNotNull);
      expect(cdkLinkTarget('https://cdk.linux.do/project'), isNull);
      expect(cdkLinkTarget('https://linux.do/receive/1'), isNull);
      expect(cdkLinkTarget('https://cdk.linux.do.evil.com/receive/1'), isNull);
    });
  });

  test('验证页 HTML：sitekey 与提示文字都转义', () {
    final html = HCaptchaSheet.buildHtml(
      siteKey: _key,
      dark: true,
      lang: 'zh-CN',
      waitingText: '<b>正在验证</b>',
    );
    expect(html, contains('sitekey:"$_key"'));
    expect(html, contains('theme:"dark"'));
    expect(html, contains('&lt;b&gt;'));
    expect(html, contains('hl=zh-CN'));
  });

  group('CdkApiService', () {
    late _Adapter adapter;
    late CdkApiService api;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      adapter = _Adapter();
      api = CdkApiService(dio: Dio()..httpClientAdapter = adapter);
    });

    test('领取：POST 带 X-Requested-With 与 captcha_token', () async {
      adapter.body = {
        'error_msg': '',
        'data': {'itemContent': 'CODE'},
      };
      final result = await api.receive('p1', 'tok');
      expect(result.itemContent, 'CODE');
      final req = adapter.requests.single;
      expect(req.method, 'POST');
      expect(
        req.uri.toString(),
        'https://cdk.linux.do/api/v1/projects/p1/receive',
      );
      expect(req.headers['X-Requested-With'], 'XMLHttpRequest');
      expect(req.data, {'captcha_token': 'tok'});
      expect(req.extra['skipCsrf'], isTrue);
    });

    test('业务错误给出后端原文；验证码被拒清掉缓存的 sitekey', () async {
      SharedPreferences.setMockInitialValues({
        'cdk_hcaptcha_sitekey': jsonEncode({
          'key': _key,
          'at': DateTime.now().millisecondsSinceEpoch,
        }),
      });
      adapter
        ..status = 400
        ..body = {'error_msg': '验证码无效，请重新验证'};
      await expectLater(
        api.receive('p1', 'tok'),
        throwsA(
          isA<CdkApiException>().having(
            (e) => e.message,
            'message',
            '验证码无效，请重新验证',
          ),
        ),
      );
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('cdk_hcaptcha_sitekey'), isNull);
    });

    test('已缓存且未过期的 sitekey 不再请求', () async {
      SharedPreferences.setMockInitialValues({
        'cdk_hcaptcha_sitekey': jsonEncode({
          'key': _key,
          'at': DateTime.now().millisecondsSinceEpoch,
        }),
      });
      expect(await api.hcaptchaSiteKey('p1'), _key);
      expect(adapter.requests, isEmpty);
    });

    test('401 视为授权过期', () async {
      adapter
        ..status = 401
        ..body = {'error_msg': 'unauthorized'};
      await expectLater(
        api.project('p1'),
        throwsA(isA<OAuthExpiredException>()),
      );
    });

    test('领取记录带分页与搜索参数', () async {
      adapter.body = {
        'error_msg': '',
        'data': {'total': 0, 'results': []},
      };
      await api.receivedHistory(page: 2, size: 20, search: ' 游戏 ');
      final q = adapter.requests.single.uri.queryParameters;
      expect(q['current'], '2');
      expect(q['size'], '20');
      expect(q['search'], '游戏');
    });
  });
}
