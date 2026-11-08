import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:app_icons/app_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:m3e_ui/m3e_ui.dart';

import '../../constants.dart';
import '../../l10n/s.dart';
import '../../models/mini_app.dart';
import '../../providers/core_providers.dart';
import '../../providers/download_provider.dart';
import '../../services/deep_link_service.dart';
import '../../services/log/log_writer.dart';
import '../../services/session/webview_use.dart';
import '../../services/toast_service.dart';
import '../../services/webview_render_gone.dart';
import '../../services/webview_settings.dart';
import '../../services/windows_webview_environment_service.dart';
import '../../utils/dialog_utils.dart';
import '../../utils/discourse_url_parser.dart';
import '../../utils/link_launcher.dart';
import '../topic_detail_page/topic_detail_page.dart';
import '../webview_page.dart';
import 'mini_app_icon.dart';

/// 藏起嵌入页自己的标题栏（图标 + 名称，原生顶栏里已经有了），应用占满整页。
/// 菜单按钮留在页面右上角、看不见也点不到，顶栏的 ⋯ 用脚本点它打开站方菜单
///（菜单按它定位，所以不能 display: none）。站方改了类名时规则不生效，页面
/// 照旧显示自己的标题栏，不影响使用
const _hideSiteHeaderCss =
    '.mini-app-page__header{position:fixed!important;top:0!important;'
    'right:8px!important;left:auto!important;width:36px!important;'
    'height:0!important;min-height:0!important;margin:0!important;'
    'padding:0!important;border:0!important;overflow:visible!important;'
    'opacity:0!important;pointer-events:none!important}';

final _chromeScript = UserScript(
  source:
      '''
(function () {
  if (window.__cfluxdoMiniAppChrome) return;
  window.__cfluxdoMiniAppChrome = true;
  var style = document.createElement('style');
  style.textContent = '$_hideSiteHeaderCss';
  (document.head || document.documentElement).appendChild(style);
})();
''',
  injectionTime: UserScriptInjectionTime.AT_DOCUMENT_END,
  forMainFrameOnly: true,
);

/// 站方加载器显示加载失败（`.mini-app-loader` 加上 is-error）时，把页面上的
/// 错误文字报给 App；重试后再失败会再报一次
final _failureWatchScript = UserScript(
  source: '''
(function () {
  if (window.__cfluxdoMiniAppWatch) return;
  window.__cfluxdoMiniAppWatch = true;
  var reported = false;
  var check = function () {
    var loader = document.querySelector('.mini-app-loader.is-error');
    if (!loader) {
      reported = false;
      return;
    }
    if (reported || !window.flutter_inappwebview) return;
    reported = true;
    var detail = loader.querySelector('[data-role="detail"]');
    window.flutter_inappwebview.callHandler(
      'cfluxdoMiniAppFailed',
      detail ? detail.textContent.trim() : ''
    );
  };
  new MutationObserver(check).observe(document.documentElement, {
    subtree: true,
    childList: true,
    attributes: true,
    attributeFilter: ['class']
  });
  check();
})();
''',
  injectionTime: UserScriptInjectionTime.AT_DOCUMENT_END,
  forMainFrameOnly: true,
);

/// 站方微应用实际用到的最新浏览器特性是 `AbortSignal.any`（Chrome 116）。
/// 低于这个版本的子框架靠 [WebViewSettings.compatPolyfillScripts] 补，再加载
/// 失败就提示用户更新系统 WebView
const _miniAppWebViewBaseline = 116;

/// 点开站方的应用菜单（应用信息、声音、分享、收藏、评分、打赏、举报）；
/// 页面里还没有菜单按钮时返回 false
const _openSiteMenuJs = '''
(function () {
  var trigger = document.querySelector('.mini-app-page__more-trigger');
  if (!trigger) return false;
  trigger.click();
  return true;
})();
''';

/// 运行一个微应用：全屏打开站方的应用嵌入页（`/apps/<id>?embed_mode=true`，
/// 帖子里嵌的就是它），顶栏换成原生的。收藏、评分、打赏、举报仍用站方页面
/// 自己的菜单，由顶栏的 ⋯ 打开
class MiniAppPage extends ConsumerStatefulWidget {
  const MiniAppPage({super.key, required this.appId, this.name, this.iconUrl});

  final String appId;

  /// 从广场进来时带上，不用等详情接口才有标题
  final String? name;
  final String? iconUrl;

  static Future<void> open(
    BuildContext context,
    String appId, {
    String? name,
    String? iconUrl,
  }) {
    return Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => MiniAppPage(appId: appId, name: name, iconUrl: iconUrl),
      ),
    );
  }

  /// 应用的公开页面（复制链接、在浏览器打开）
  static String pageUrl(String appId) =>
      '${AppConstants.baseUrl}/apps/${Uri.encodeComponent(appId)}';

  static String embedUrl(String appId) => '${pageUrl(appId)}?embed_mode=true';

  @override
  ConsumerState<MiniAppPage> createState() => _MiniAppPageState();
}

class _MiniAppPageState extends ConsumerState<MiniAppPage>
    with WebViewRenderGoneState<MiniAppPage> {
  InAppWebViewController? _controller;

  /// 与内置浏览器同一口径：加载前从 jar 重灌登录 cookie，期间定期、关页时把
  /// 应用页里请求轮换过的 `_t` 交给 authority
  late final WebViewUse _webViewUse;
  Timer? _sessionTokenReconcileTimer;
  static const Duration _sessionTokenReconcileInterval = Duration(seconds: 60);

  /// 应用详情：顶栏标题、图标、讨论主题
  MiniApp? _app;

  /// 详情拿不到时用页面标题（「名称 - 站点名」）
  String? _pageTitle;
  bool _loadedOnce = false;
  bool _isLoading = true;
  double _progress = 0;
  bool _canGoBack = false;

  /// 各框架最近的未捕获异常。站方把应用启动时的异常一律报成「浏览器无法安全
  /// 运行此应用」，真正的原因只在这里，加载失败时一起记进日志
  final List<String> _uncaughtErrors = [];

  /// 系统 WebView 比站方要求的旧、应用又加载失败时，页面顶上提示去更新
  ({int major, String? package})? _outdatedWebView;

  String get _embedUrl => MiniAppPage.embedUrl(widget.appId);

  @override
  void initState() {
    super.initState();
    _webViewUse = WebViewUses.instance.start(
      WebViewUsePurpose.browsing,
      url: _embedUrl,
      reason: 'mini_app',
    );
    _sessionTokenReconcileTimer = Timer.periodic(
      _sessionTokenReconcileInterval,
      (_) {
        if (!_loadedOnce) return;
        unawaited(
          _webViewUse.checkpoint(
            WebViewUseOutcome.loaded,
            reason: 'mini_app_tick',
          ),
        );
      },
    );
    _loadInfo();
  }

  @override
  void dispose() {
    _sessionTokenReconcileTimer?.cancel();
    unawaited(
      _loadedOnce
          ? _webViewUse.end(
              WebViewUseOutcome.loaded,
              reason: 'mini_app_dispose',
            )
          : _webViewUse.end(WebViewUseOutcome.aborted),
    );
    _controller?.dispose();
    super.dispose();
  }

  @override
  void onWebViewDiscarded() {
    _controller = null;
    _isLoading = false;
    _canGoBack = false;
  }

  Future<void> _loadInfo() async {
    try {
      final app = await ref
          .read(discourseServiceProvider)
          .getMiniApp(widget.appId);
      if (mounted) setState(() => _app = app);
    } catch (e) {
      // 只影响顶栏标题和「参与讨论」；应用照常加载，出错由站方页面提示
      debugPrint('[MiniApp] 获取应用详情失败: $e');
    }
  }

  void _recordUncaughtError(ConsoleMessage message) {
    final text = message.message;
    if (message.messageLevel != ConsoleMessageLevel.ERROR ||
        !text.startsWith('Uncaught')) {
      return;
    }
    if (_uncaughtErrors.length == 3) _uncaughtErrors.removeAt(0);
    _uncaughtErrors.add(text.length > 300 ? text.substring(0, 300) : text);
  }

  /// 站方页面显示了加载失败：记日志（带 WebView 版本和未捕获异常），WebView
  /// 太旧时提示更新
  Future<void> _onAppFailed(String detail) async {
    final appId = widget.appId;
    final uncaughtErrors = List.of(_uncaughtErrors);
    // 版本以探到的 UA 为准：厂商自带的 WebView 包版本号不是 Chromium 版本
    final ua = AppConstants.webViewUserAgentIfKnown;
    final major = ua == null
        ? null
        : int.tryParse(RegExp(r'Chrome/(\d+)').firstMatch(ua)?.group(1) ?? '');
    WebViewPackageInfo? webView;
    if (Platform.isAndroid) {
      try {
        webView = await InAppWebViewController.getCurrentWebViewPackage();
      } catch (_) {}
    }
    LogWriter.instance.write({
      'timestamp': DateTime.now().toIso8601String(),
      'level': 'warning',
      'type': 'webview',
      'event': 'mini_app_load_failed',
      'message': detail,
      'appId': appId,
      'chromeMajor': major,
      'webViewPackage': webView?.packageName,
      'webViewVersion': webView?.versionName,
      'uncaughtErrors': uncaughtErrors,
    });
    if (major == null || major >= _miniAppWebViewBaseline || !mounted) return;
    setState(() {
      _outdatedWebView = (major: major, package: webView?.packageName);
    });
  }

  Future<void> _openWebViewStore(String package) async {
    if (await openWithSystem(Uri.parse('market://details?id=$package'))) {
      return;
    }
    if (!await launchInExternalBrowser(
      'https://play.google.com/store/apps/details?id=$package',
    )) {
      ToastService.showError(S.current.webview_cannotOpenBrowser);
    }
  }

  String get _title => _app?.name ?? widget.name ?? _pageTitle ?? '';

  String? get _iconUrl => _app?.iconUrl ?? widget.iconUrl;

  bool _isThisApp(Uri uri) {
    if (!isInternalUrl(uri)) return false;
    final appId = DiscourseUrlParser.parseMiniApp(uri.toString())?.appId;
    return appId != null && appId == widget.appId.toLowerCase();
  }

  /// 页面里点出去的链接：站内话题、用户等用原生页面打开，站外的走外链确认
  void _openLink(String url) {
    launchContentLink(
      context,
      url,
      onInternalLinkTap: (topicId, slug, postNumber) =>
          _openTopic(topicId, postNumber: postNumber),
    );
  }

  void _openTopic(int topicId, {int? postNumber}) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            TopicDetailPage(topicId: topicId, scrollToPostNumber: postNumber),
      ),
    );
  }

  Future<void> _handleBack() async {
    final controller = _controller;
    if (controller != null && await controller.canGoBack()) {
      await controller.goBack();
      return;
    }
    if (mounted) Navigator.of(context).pop();
  }

  void _reload() {
    if (webViewRenderGone) {
      reloadAfterRenderGone();
      return;
    }
    _controller?.reload();
  }

  Future<void> _openMenu() async {
    final controller = _controller;
    if (controller != null && !webViewRenderGone) {
      try {
        final opened = await controller.evaluateJavascript(
          source: _openSiteMenuJs,
        );
        if (opened == true) return;
      } catch (e) {
        debugPrint('[MiniApp] 打开站方菜单失败: $e');
      }
    }
    if (mounted) _showFallbackMenu();
  }

  /// 站方菜单还没出来（页面没加载完 / 站方改版）时的原生菜单
  void _showFallbackMenu() {
    final topicId = _app?.discussionTopicId;
    final pageUrl = MiniAppPage.pageUrl(widget.appId);
    showAppBottomSheet<void>(
      context: context,
      showDragHandle: true,
      // 底下是实时 WebView，模糊它会掉帧
      blur: false,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (topicId != null)
              ListTile(
                leading: const Icon(Symbols.forum_rounded),
                title: Text(context.l10n.miniApp_discussion),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _openTopic(topicId);
                },
              ),
            ListTile(
              leading: const Icon(Symbols.content_copy_rounded),
              title: Text(context.l10n.common_copyLink),
              onTap: () async {
                Navigator.pop(sheetContext);
                await Clipboard.setData(ClipboardData(text: pageUrl));
                ToastService.showSuccess(S.current.common_linkCopied);
              },
            ),
            ListTile(
              leading: const Icon(Symbols.open_in_browser_rounded),
              title: Text(context.l10n.webview_openExternal),
              onTap: () async {
                Navigator.pop(sheetContext);
                if (!await launchInExternalBrowser(pageUrl)) {
                  ToastService.showError(S.current.webview_cannotOpenBrowser);
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<NavigationActionPolicy> _shouldOverrideUrlLoading(
    InAppWebViewController controller,
    NavigationAction action,
  ) async {
    final uri = action.request.url;
    // 应用本身跑在子框架里（sandbox），它的加载一律放行
    if (uri == null || action.isForMainFrame != true) {
      return NavigationActionPolicy.ALLOW;
    }
    final scheme = uri.scheme.toLowerCase();
    if (scheme == 'fluxdo' || scheme == 'discourse') {
      DeepLinkService.instance.handleUri(uri);
      return NavigationActionPolicy.CANCEL;
    }
    if (scheme != 'http' && scheme != 'https') {
      return const {'about', 'data', 'blob'}.contains(scheme)
          ? NavigationActionPolicy.ALLOW
          : NavigationActionPolicy.CANCEL;
    }
    if (_isThisApp(uri)) return NavigationActionPolicy.ALLOW;
    // 用户点出去的链接不在应用页里打开；页面自己的跳转（过验证等）照常
    if (action.navigationType == NavigationType.LINK_ACTIVATED ||
        action.hasGesture == true) {
      if (mounted) _openLink(uri.toString());
      return NavigationActionPolicy.CANCEL;
    }
    return NavigationActionPolicy.ALLOW;
  }

  Future<void> _onHistoryChanged(
    InAppWebViewController controller,
    WebUri? url,
  ) async {
    final canGoBack = await controller.canGoBack();
    if (!mounted || webViewRenderGone) return;
    if (_loadedOnce &&
        url != null &&
        (url.scheme == 'https' || url.scheme == 'http') &&
        !_isThisApp(url)) {
      // 站方页面是单页应用，应用信息里的讨论主题、开发者等链接在页内换页
      // 而不是导航：退回应用，目标用原生页面打开
      if (canGoBack) {
        await controller.goBack();
      } else {
        await controller.loadUrl(
          urlRequest: URLRequest(url: WebUri(_embedUrl)),
        );
      }
      if (mounted) _openLink(url.toString());
      return;
    }
    if (canGoBack != _canGoBack) setState(() => _canGoBack = canGoBack);
  }

  /// 网页开新窗口（应用的「打开链接」、站方页面的新标签页链接）
  Future<bool?> _onCreateWindow(
    InAppWebViewController controller,
    CreateWindowAction action,
  ) async {
    if (!mounted) return false;
    final url = action.request.url;
    // 点的是站内链接：原生页面打开，不开窗口
    if (url != null &&
        (url.scheme == 'https' || url.scheme == 'http') &&
        isInternalUrl(url) &&
        !_isThisApp(url)) {
      _openLink(url.toString());
      return false;
    }
    // 其余叠一页内置浏览器承载；必须同步答应，地址由网页随后加载进去
    unawaited(
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => WebViewPage(
            url: url?.toString() ?? '',
            allowPopups: true,
            windowId: action.windowId,
          ),
        ),
      ),
    );
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final iconUrl = _iconUrl;
    final outdatedWebView = _outdatedWebView;
    return PopScope(
      // 应用里还有历史（单页应用切了页面）时，返回键先回退应用
      canPop: !_canGoBack,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_handleBack());
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Symbols.close_rounded),
            tooltip: context.l10n.common_close,
            onPressed: () => Navigator.of(context).pop(),
          ),
          titleSpacing: 0,
          title: Row(
            children: [
              if (iconUrl != null) ...[
                MiniAppIcon(url: iconUrl, size: 28),
                const SizedBox(width: 10),
              ],
              Flexible(
                child: Text(
                  _title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          actions: [
            IconButton(
              icon: const Icon(Symbols.refresh_rounded),
              tooltip: context.l10n.common_refresh,
              onPressed: _reload,
            ),
            IconButton(
              icon: const Icon(Symbols.more_horiz_rounded),
              tooltip: context.l10n.miniApp_menu,
              onPressed: _openMenu,
            ),
          ],
        ),
        body: webViewRenderGone
            ? WebViewRenderGoneView(onReload: reloadAfterRenderGone)
            : Column(
                children: [
                  if (outdatedWebView != null)
                    _buildOutdatedBanner(outdatedWebView),
                  Expanded(
                    child: Stack(
                      children: [
                        Positioned.fill(child: _buildWebView()),
                        if (_isLoading)
                          Positioned(
                            top: 0,
                            left: 0,
                            right: 0,
                            child: M3eLinearProgress(
                              value: _progress,
                              trackColor:
                                  theme.colorScheme.surfaceContainerHighest,
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  Widget _buildOutdatedBanner(({int major, String? package}) outdated) {
    final package = outdated.package;
    return MaterialBanner(
      leading: const Icon(Symbols.system_update_rounded),
      content: Text(context.l10n.miniApp_webViewOutdated(outdated.major)),
      actions: [
        if (package != null)
          TextButton(
            onPressed: () => _openWebViewStore(package),
            child: Text(context.l10n.miniApp_updateWebView),
          ),
        TextButton(
          onPressed: () => setState(() => _outdatedWebView = null),
          child: Text(context.l10n.common_close),
        ),
      ],
    );
  }

  Widget _buildWebView() {
    return WebViewSettings.wrapWithScrollFix(
      InAppWebView(
        key: ValueKey(webViewGeneration),
        webViewEnvironment:
            WindowsWebViewEnvironmentService.instance.environment,
        initialSettings: WebViewSettings.visible
          ..useShouldOverrideUrlLoading = true
          ..supportMultipleWindows = true
          ..javaScriptCanOpenWindowsAutomatically = true,
        initialUserScripts: UnmodifiableListView([
          ...WebViewSettings.compatPolyfillScripts,
          _chromeScript,
          _failureWatchScript,
        ]),
        onWebViewCreated: (controller) async {
          _controller = controller;
          WebViewSettings.registerJsErrorReporter(controller);
          controller.addJavaScriptHandler(
            handlerName: 'cfluxdoMiniAppFailed',
            callback: (args) {
              if (mounted) {
                unawaited(_onAppFailed(args.isEmpty ? '' : '${args.first}'));
              }
              return null;
            },
          );
          // 等使用期的准备（重灌 cookie）完成再加载，否则应用当成没登录。
          // 回调里拿到的 controller 每次是新包装，不能按对象比，按代数比
          final generation = webViewGeneration;
          await _webViewUse.ready;
          if (!mounted ||
              webViewRenderGone ||
              generation != webViewGeneration) {
            return;
          }
          await controller.loadUrl(
            urlRequest: URLRequest(
              url: WebUri(_embedUrl),
              headers: {'Referer': AppConstants.baseUrl},
            ),
          );
        },
        shouldOverrideUrlLoading: _shouldOverrideUrlLoading,
        onCreateWindow: _onCreateWindow,
        onReceivedServerTrustAuthRequest: (_, challenge) =>
            WebViewSettings.handleServerTrustAuthRequest(challenge),
        onRenderProcessGone: (_, detail) =>
            handleWebViewRenderGone('mini_app', detail),
        onLoadStart: (controller, url) {
          _uncaughtErrors.clear();
          if (mounted) setState(() => _isLoading = true);
        },
        onProgressChanged: (controller, progress) {
          if (mounted) setState(() => _progress = progress / 100);
        },
        onLoadStop: (controller, url) async {
          _loadedOnce = true;
          await WebViewSettings.injectScrollFix(controller);
          final canGoBack = await controller.canGoBack();
          if (!mounted || webViewRenderGone) return;
          setState(() {
            _isLoading = false;
            _canGoBack = canGoBack;
          });
        },
        onUpdateVisitedHistory: (controller, url, isReload) =>
            _onHistoryChanged(controller, url),
        onConsoleMessage: (controller, message) =>
            _recordUncaughtError(message),
        onTitleChanged: (controller, title) {
          if (title == null || title.isEmpty || !mounted) return;
          final separator = title.lastIndexOf(' - ');
          setState(() {
            _pageTitle = separator > 0 ? title.substring(0, separator) : title;
          });
        },
        onDownloadStarting: (controller, request) {
          final url = request.url;
          // 应用「保存文件」给的是 blob: 地址，下载器拿不到，只接普通链接
          if (url.scheme != 'https' && url.scheme != 'http') return null;
          ref
              .read(downloadProvider.notifier)
              .startDownload(
                url: url.toString(),
                suggestedFilename: request.suggestedFilename,
                mimeType: request.mimeType,
                contentLength: request.contentLength,
              );
          return null;
        },
      ),
      getController: () => _controller,
    );
  }
}
