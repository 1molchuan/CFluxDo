import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../l10n/s.dart';
import '../../services/webview_settings.dart';
import '../../services/windows_webview_environment_service.dart';
import '../common/app_bottom_sheet.dart';

/// 只装 hCaptcha 的验证层：CDK 领取前拿一枚一次性令牌。
///
/// 页面用 loadData 以 `https://cdk.linux.do/receive/<id>` 为源加载（hCaptcha 按
/// 宿主页的 hostname 校验 sitekey 的授权域名），不请求 CDK 站本身，只加载
/// js.hcaptcha.com。隐形模式：多数情况直接出令牌，风险高时 hCaptcha 会在页面里
/// 弹点图挑战，所以弹层留足高度。返回令牌；用户关掉或失败返回 null。
class HCaptchaSheet extends StatefulWidget {
  const HCaptchaSheet({
    super.key,
    required this.siteKey,
    required this.hostUrl,
  });

  final String siteKey;

  /// 宿主页地址（决定 hCaptcha 看到的 hostname）
  final String hostUrl;

  static Future<String?> show(
    BuildContext context, {
    required String siteKey,
    required String hostUrl,
  }) {
    return AppBottomSheet.show<String>(
      context: context,
      title: S.current.cdkPage_captchaTitle,
      contentPadding: EdgeInsets.zero,
      maxHeightFactor: 0.85,
      enableDrag: false,
      builder: (_) => HCaptchaSheet(siteKey: siteKey, hostUrl: hostUrl),
    );
  }

  /// 拼验证页。[siteKey] 只接受 uuid，避免注入
  @visibleForTesting
  static String buildHtml({
    required String siteKey,
    required bool dark,
    required String lang,
    required String waitingText,
  }) {
    final key = jsonEncode(siteKey);
    final theme = jsonEncode(dark ? 'dark' : 'light');
    final hl = Uri.encodeQueryComponent(lang);
    final bg = dark ? '#1c1b1f' : '#ffffff';
    final fg = dark ? '#c9c5ca' : '#5f5d62';
    final waiting = const HtmlEscape().convert(waitingText);
    return '''<!doctype html>
<html><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1">
<style>
html,body{margin:0;height:100%;background:$bg;color:$fg;font:15px/1.5 sans-serif}
#tip{position:absolute;inset:0;display:flex;align-items:center;justify-content:center}
</style>
<script>
var ready=!!(window.flutter_inappwebview&&window.flutter_inappwebview.callHandler),q=[];
function post(t,v){if(ready){window.flutter_inappwebview.callHandler('hcaptcha',t,v||'');}else{q.push([t,v]);}}
window.addEventListener('flutterInAppWebViewPlatformReady',function(){ready=true;while(q.length){var m=q.shift();post(m[0],m[1]);}});
function onHc(){
  try{
    var id=hcaptcha.render('box',{sitekey:$key,size:'invisible',theme:$theme,
      callback:function(t){post('token',t);},
      'error-callback':function(e){post('error',String(e||''));},
      'expired-callback':function(){post('expired');},
      'chalexpired-callback':function(){post('expired');},
      'close-callback':function(){post('closed');}});
    hcaptcha.execute(id);
  }catch(e){post('error',String(e));}
}
</script>
<script src="https://js.hcaptcha.com/1/api.js?onload=onHc&render=explicit&recaptchacompat=off&hl=$hl" async defer onerror="post('error','script')"></script>
</head><body><div id="tip">$waiting</div><div id="box"></div></body></html>''';
  }

  @override
  State<HCaptchaSheet> createState() => _HCaptchaSheetState();
}

class _HCaptchaSheetState extends State<HCaptchaSheet> {
  Timer? _timeout;
  String? _error;
  bool _done = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _armTimeout();
  }

  @override
  void dispose() {
    _timeout?.cancel();
    super.dispose();
  }

  /// 挑战可能要点好一会儿图，只在迟迟没有任何结果时兜底
  void _armTimeout() {
    _timeout?.cancel();
    _timeout = Timer(const Duration(seconds: 90), () {
      if (!mounted || _done) return;
      setState(() => _error = S.current.cdkPage_captchaTimeout);
    });
  }

  void _finish(String token) {
    if (_done || !mounted) return;
    _done = true;
    _timeout?.cancel();
    Navigator.of(context).pop(token);
  }

  void _onMessage(List<dynamic> args) {
    if (!mounted || _done) return;
    final type = args.isNotEmpty ? args[0]?.toString() : null;
    final value = args.length > 1 ? args[1]?.toString() ?? '' : '';
    switch (type) {
      case 'token':
        if (value.isNotEmpty) _finish(value);
      case 'closed':
        // 用户关掉了点图挑战：等同取消
        Navigator.of(context).maybePop();
      case 'expired':
        setState(() => _error = S.current.cdkPage_captchaExpired);
      default:
        setState(
          () => _error = value == 'script'
              ? S.current.cdkPage_captchaLoadFailed
              : S.current.cdkPage_captchaFailed(value),
        );
    }
  }

  void _retry() {
    setState(() {
      _error = null;
      _generation++;
    });
    _armTimeout();
  }

  String _lang(BuildContext context) {
    final locale = Localizations.maybeLocaleOf(context);
    if (locale == null || locale.languageCode != 'zh') return 'en';
    final region = locale.countryCode ?? '';
    final script = locale.scriptCode ?? '';
    return region == 'TW' || region == 'HK' || script == 'Hant'
        ? 'zh-TW'
        : 'zh-CN';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final height = MediaQuery.sizeOf(context).height * 0.7;
    final error = _error;
    if (error != null) {
      return SizedBox(
        height: 220,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  error,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 16),
                FilledButton.tonal(
                  onPressed: _retry,
                  child: Text(S.current.common_retry),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final settings = WebViewSettings.visible
      ..transparentBackground = false
      ..supportZoom = false;
    return SizedBox(
      height: height,
      child: InAppWebView(
        key: ValueKey(_generation),
        webViewEnvironment: !kIsWeb && Platform.isWindows
            ? WindowsWebViewEnvironmentService.instance.environment
            : null,
        initialData: InAppWebViewInitialData(
          data: HCaptchaSheet.buildHtml(
            siteKey: widget.siteKey,
            dark: theme.brightness == Brightness.dark,
            lang: _lang(context),
            waitingText: S.current.cdkPage_captchaWaiting,
          ),
          baseUrl: WebUri(widget.hostUrl),
          historyUrl: WebUri(widget.hostUrl),
        ),
        initialSettings: settings,
        initialUserScripts: WebViewSettings.compatPolyfillScripts,
        onWebViewCreated: (controller) {
          WebViewSettings.registerJsErrorReporter(controller);
          controller.addJavaScriptHandler(
            handlerName: 'hcaptcha',
            callback: (args) {
              _onMessage(args);
              return null;
            },
          );
        },
        onReceivedServerTrustAuthRequest: (_, challenge) =>
            WebViewSettings.handleServerTrustAuthRequest(challenge),
        onRenderProcessGone: (_, _) {
          if (mounted && !_done) {
            setState(() => _error = S.current.cdkPage_captchaLoadFailed);
          }
        },
        // 挑战里的链接（隐私政策等）不在这个小窗里打开
        shouldOverrideUrlLoading: (_, action) async {
          final url = action.request.url;
          if (url == null || !action.isForMainFrame) {
            return NavigationActionPolicy.ALLOW;
          }
          final host = url.host;
          if (host.endsWith('hcaptcha.com') ||
              url.toString() == widget.hostUrl ||
              url.scheme == 'about' ||
              url.scheme == 'data') {
            return NavigationActionPolicy.ALLOW;
          }
          return NavigationActionPolicy.CANCEL;
        },
      ),
    );
  }
}
