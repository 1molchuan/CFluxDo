import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:html/parser.dart' as html_parser;

import '../../../utils/dialog_utils.dart';
import '../../local_notification_service.dart' show navigatorKey;
import '../../oauth_flow_helper.dart';
import '../discourse_dio.dart';
import '../flux_request_spec.dart';

enum AccelDohConnectOutcome {
  /// 拿到了回调里的 code/state
  code,

  /// 这个账号用不了 Connect（没有授权页，或 Connect 直接报错）
  unavailable,

  /// 网络问题，稍后再试
  failed,
}

class AccelDohConnectResult {
  const AccelDohConnectResult.code(String this.code, String this.state)
    : outcome = AccelDohConnectOutcome.code;

  const AccelDohConnectResult.unavailable()
    : outcome = AccelDohConnectOutcome.unavailable,
      code = null,
      state = null;

  const AccelDohConnectResult.failed()
    : outcome = AccelDohConnectOutcome.failed,
      code = null,
      state = null;

  final AccelDohConnectOutcome outcome;
  final String? code;
  final String? state;
}

/// 在 App 里走一遍 LinuxDo Connect 授权，拿到回调里的 code/state
///
/// 只有发往 linux.do 系域名的请求走 App 的 Dio（带 L 站登录态，用来证明身份）。
/// 跳回加速服务端的那一跳不会真的发出去，只从 Location 里取 code/state，
/// 再由 AccelDohAuthService 交给服务端。
class AccelDohConnectFlow {
  static const int _maxRedirects = 8;

  Dio? _dio;

  Dio get _client => _dio ??= DiscourseDio.create();

  /// 弹窗征求同意；返回 null 表示现在没法弹（不在前台或界面还没起来）
  Future<bool?> askConsent() async {
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (lifecycle != null && lifecycle != AppLifecycleState.resumed) {
      return null;
    }
    final context = navigatorKey.currentContext;
    if (context == null || !context.mounted) return null;
    final result = await showAppDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => const _ConsentDialog(),
    );
    return result ?? false;
  }

  /// [silent] 为 true 时是后台自动续期：不弹错误提示，CF 盾只在后台验证
  Future<AccelDohConnectResult> fetchCode(
    Uri authorizeUrl, {
    bool silent = true,
  }) async {
    try {
      // 模拟"业务页加载完成 → 跳转到授权页"的导航延迟
      await OAuthFlowHelper.humanGap(minMs: 800, maxMs: 1500);

      var uri = authorizeUrl;
      var response = await _get(uri, silent: silent);
      for (var hop = 0; ; hop++) {
        final next = _redirectTarget(response, uri);
        if (next == null) break;
        // 之前授权过的应用，Connect 可能直接跳回回调地址
        final callback = _callbackOf(next);
        if (callback != null) return callback;
        if (!_isLinuxDoHost(next.host) || hop >= _maxRedirects) {
          debugPrint('[DOH] Connect 授权跳到了意外的地址: ${next.host}');
          return const AccelDohConnectResult.unavailable();
        }
        uri = next;
        response = await _get(uri, silent: silent);
      }

      if (response.statusCode != 200) {
        debugPrint('[DOH] Connect 授权页打不开: HTTP ${response.statusCode}');
        return const AccelDohConnectResult.failed();
      }
      final data = response.data;
      final approveLink = html_parser
          .parse(data is String ? data : '')
          .querySelector('a[href*="/oauth2/approve/"]')
          ?.attributes['href'];
      if (approveLink == null) {
        debugPrint('[DOH] Connect 授权页没有同意按钮，当作此账号不能用 Connect');
        return const AccelDohConnectResult.unavailable();
      }
      final approveUri = uri.resolve(approveLink);
      if (approveUri.scheme != 'https' || approveUri.host != uri.host) {
        return const AccelDohConnectResult.unavailable();
      }

      // 模拟点击同意的反应时间
      await OAuthFlowHelper.humanGap(minMs: 600, maxMs: 1200);

      // 这一跳会跳到加速服务端，不能把 Set-Cookie 另存到那个域名下
      final approveResponse = await _get(
        approveUri,
        silent: silent,
        allowRedirectSetCookie: false,
      );
      final next = _redirectTarget(approveResponse, approveUri);
      final callback = next == null ? null : _callbackOf(next);
      if (callback == null) {
        debugPrint('[DOH] Connect 同意后没有拿到 code');
        return const AccelDohConnectResult.unavailable();
      }

      // 模拟浏览器跳回业务方的延迟
      await OAuthFlowHelper.humanGap(minMs: 400, maxMs: 900);
      return callback;
    } on DioException catch (e) {
      debugPrint('[DOH] Connect 授权请求失败: ${e.type} ${e.message}');
      return const AccelDohConnectResult.failed();
    }
  }

  /// 每一跳都手动处理：自动跟随会把回调地址也请求一遍
  Future<Response<dynamic>> _get(
    Uri uri, {
    required bool silent,
    bool allowRedirectSetCookie = true,
  }) {
    return _client.getUri<dynamic>(
      uri,
      options: Options(
        followRedirects: false,
        responseType: ResponseType.plain,
        // 4xx 也按错误走：CF 的 403/429 挑战要进 CfChallengeInterceptor 过盾后重放，
        // 之前把 <500 都当正常响应，撞盾就直接「授权页打不开」失败。
        // 移动网络换出口 IP 后 cf_clearance 失效、撞盾很常见
        validateStatus: (status) => status != null && status < 400,
        extra: {
          FluxRequestKeys.skipCsrf: true,
          FluxRequestKeys.skipRedirect: true,
          FluxRequestKeys.skipAuthCheck: true,
          FluxRequestKeys.allowRedirectSetCookie: allowRedirectSetCookie,
          FluxRequestKeys.isSilent: silent,
          // 用户手动授权时按「操作」对待：撞 CF 盾弹验证页让用户过盾，
          // 而不是像数据请求那样静默失败让用户再点一次
          if (!silent) FluxRequestKeys.showErrorToast: true,
          FluxRequestKeys.requestTag: 'accel_doh_connect',
        },
      ),
    );
  }

  static Uri? _redirectTarget(Response<dynamic> response, Uri from) {
    final status = response.statusCode ?? 0;
    if (status < 300 || status >= 400) return null;
    final location = response.headers.value('location');
    if (location == null || location.isEmpty) return null;
    return from.resolve(location);
  }

  /// 跳出 linux.do、带着 code 和 state 的地址就是授权回调
  static AccelDohConnectResult? _callbackOf(Uri uri) {
    if (_isLinuxDoHost(uri.host)) return null;
    final code = uri.queryParameters['code'];
    final state = uri.queryParameters['state'];
    if (code == null || code.isEmpty || state == null || state.isEmpty) {
      return null;
    }
    return AccelDohConnectResult.code(code, state);
  }

  static bool _isLinuxDoHost(String host) =>
      host == 'linux.do' || host.endsWith('.linux.do');
}

class _ConsentDialog extends StatelessWidget {
  const _ConsentDialog();

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('开启 cfluxdo 加速'),
      content: const Text(
        'cfluxdo 加速需要用 L 站 Connect 确认一次你的账号。\n\n'
        '加速服务端只会拿到你的 L 站 id、用户名、信任等级这类基本资料，'
        '拿不到你的登录凭据。\n\n'
        '每个账号最多 3 台设备，第 4 台授权时最早授权的那台会被挤掉。\n\n'
        '不授权也能用，会改走公共加速。',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('暂不'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('授权'),
        ),
      ],
    );
  }
}
