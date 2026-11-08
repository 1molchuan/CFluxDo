import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:m3e_ui/m3e_ui.dart';
import '../../../../config/forum_site.dart';
import '../../../../constants.dart';
import '../../../../utils/discourse_url_parser.dart';
import '../../../../utils/layout_lock.dart';
import '../../../../utils/url_helper.dart';
import '../../../../pages/mini_app/mini_app_page.dart';
import '../../../../pages/webview_page.dart';
import '../../../../l10n/s.dart';
import '../../../../services/navigation/app_route_observer.dart';
import '../../../../services/session/webview_use.dart';
import '../../../../services/site_context.dart';
import '../../../../services/embedded_browser_controller_pool.dart';
import '../../../../services/dynamic_content_suspension_service.dart';
import '../../../../services/webview_render_gone.dart';
import '../../../../services/webview_settings.dart';
import '../../../../services/windows_webview_environment_service.dart';

/// 是否需要交互遮罩（macOS 上 WebView 会捕获滚动事件）
bool get _needsInteractionMask => !kIsWeb && Platform.isMacOS;

/// 本站嵌入页 `window.open` 开的新窗口叠一页内置浏览器承载（Android）。linux.do 微应用
/// （红包等）的「打开链接」是站方宿主脚本在用户确认后 window.open（应用本身在 sandbox
/// 里开不了窗口）：不接的话 Android 在这个嵌入框里直接换成新页面，帖子里的应用被顶掉。
/// 其他平台没验过新窗口接管，保持原样
bool get _supportsPopupPages => !kIsWeb && Platform.isAndroid;

/// iframe 属性解析结果
class IframeAttributes {
  final String src;
  final double? width;
  final double? height;
  final Set<String>? sandbox;
  final Set<String> allow;
  final bool allowFullscreen;
  final String? referrerPolicy;
  final bool lazyLoad;
  final String? title;
  final Set<String> classes;

  IframeAttributes({
    required this.src,
    this.width,
    this.height,
    this.sandbox,
    this.allow = const {},
    this.allowFullscreen = false,
    this.referrerPolicy,
    this.lazyLoad = false,
    this.title,
    this.classes = const {},
  });

  /// 从 HTML element 解析 iframe 属性
  factory IframeAttributes.fromElement(dynamic element) {
    final attrs = element.attributes;

    // src 属性
    final src =
        (attrs['src'] as String?) ?? (attrs['data-src'] as String?) ?? '';

    // 宽高属性
    final width = double.tryParse(attrs['width'] as String? ?? '');
    final height = double.tryParse(attrs['height'] as String? ?? '');

    // class 属性
    final classAttr = attrs['class'] as String?;
    final classes = classAttr?.split(RegExp(r'\s+')).toSet() ?? {};

    // sandbox 属性
    final sandboxAttr = attrs['sandbox'] as String?;
    final sandbox = sandboxAttr?.split(RegExp(r'\s+')).toSet();

    // allow 属性 (Permissions Policy)
    final allowAttr = attrs['allow'] as String?;
    final allow =
        allowAttr
            ?.split(';')
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .toSet() ??
        {};

    // allowfullscreen 属性
    final allowFullscreen =
        attrs.containsKey('allowfullscreen') ||
        attrs['allowfullscreen'] == 'true' ||
        attrs['allowfullscreen'] == '' ||
        allow.any((p) => p.startsWith('fullscreen'));

    // referrerpolicy 属性
    final referrerPolicy = attrs['referrerpolicy'] as String?;

    // loading 属性
    final loadingAttr = attrs['loading'] as String?;
    final lazyLoad = loadingAttr == 'lazy';

    // title 属性
    final title = attrs['title'] as String?;

    return IframeAttributes(
      src: src,
      width: width,
      height: height,
      sandbox: sandbox,
      allow: allow,
      allowFullscreen: allowFullscreen,
      referrerPolicy: referrerPolicy,
      lazyLoad: lazyLoad,
      title: title,
      classes: classes,
    );
  }

  /// 是否允许脚本执行
  bool get allowScripts =>
      sandbox == null || sandbox!.contains('allow-scripts');

  /// 是否允许自动播放
  bool get allowAutoplay => allow.any((p) => p.startsWith('autoplay'));

  /// 计算宽高比
  double get aspectRatio {
    // 视频 onebox 强制使用 16:9（遵循 Discourse CSS 规则）
    if (classes.contains('youtube-onebox') ||
        classes.contains('lazyYT') ||
        classes.contains('vimeo-onebox') ||
        classes.contains('loom-onebox')) {
      return 16 / 9;
    }

    // 其他情况：如果有明确的宽高，使用计算值
    if (width != null && width! > 0 && height != null && height! > 0) {
      return width! / height!;
    }

    // 默认 16:9
    return 16 / 9;
  }

  /// 获取完整 URL
  String get fullUrl => UrlHelper.resolveUrl(src);
}

/// iframe Widget
class IframeWidget extends StatefulWidget {
  final IframeAttributes attributes;

  const IframeWidget({super.key, required this.attributes});

  @override
  State<IframeWidget> createState() => _IframeWidgetState();
}

class _IframeWidgetState extends State<IframeWidget> with RouteAware {
  bool _isLoaded = false;
  bool _hasError = false;
  bool _didLockLayout = false;
  bool _webViewActivated = false;
  EmbeddedBrowserLease? _browserLease;

  /// WebView 渲染进程没了：实例已不能再用，摘掉后由用户点重新加载
  bool _renderGone = false;
  int _webViewGeneration = 0;

  /// 桌面平台：是否进入交互模式
  bool _interacting = false;
  OverlayEntry? _overlayEntry;

  /// 上层路由（对话框/BottomSheet）出现时隐藏 WebView，
  /// 避免 hybrid composition 持续脏帧触发 BackdropFilter 全屏重算。
  bool _routeOverlayed = false;

  /// 本站页面（微应用、红包等）的 WebView 使用期：加载前从 jar 重灌登录 cookie，
  /// 关掉时把页内请求轮换过的 `_t` 交给 authority，与内置浏览器同一口径。
  /// 不灌的话 WebView 带着旧的或空的 `_t` 打开，微应用当成没登录（「检查访问权限」）
  WebViewUse? _webViewUse;
  bool _loadedOnce = false;

  /// 新窗口只给本站页面接（见 [_supportsPopupPages]）；第三方嵌入照旧
  bool get _allowPopups => _supportsPopupPages && _webViewUse != null;

  /// 嵌的是微应用（/apps/<应用 ID>）时的应用 ID：帖子里的框只能横向操作、
  /// 纵向滚不动，下面给一个全屏打开的入口
  String? _miniAppId;

  @override
  void initState() {
    super.initState();
    DynamicContentSuspensionService.instance.addListener(
      _handleDynamicContentSuspension,
    );
    final uri = Uri.tryParse(widget.attributes.fullUrl);
    if (uri != null && ForumSite.fromUri(uri) == SiteContext.current) {
      _webViewUse = WebViewUses.instance.start(
        WebViewUsePurpose.browsing,
        url: widget.attributes.fullUrl,
        reason: 'post_iframe',
      );
      _miniAppId = DiscourseUrlParser.parseMiniApp(
        widget.attributes.fullUrl,
      )?.appId;
    }
  }

  void _handleDynamicContentSuspension() {
    if (!DynamicContentSuspensionService.instance.suspended) return;
    _removeOverlay();
    if (_webViewActivated) _deactivateWindowsWebView();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route != null) {
      appRouteObserver.subscribe(this, route);
    }
  }

  @override
  void didPushNext() {
    if (!_routeOverlayed) setState(() => _routeOverlayed = true);
  }

  @override
  void didPopNext() {
    if (_routeOverlayed) setState(() => _routeOverlayed = false);
  }

  @override
  void dispose() {
    DynamicContentSuspensionService.instance.removeListener(
      _handleDynamicContentSuspension,
    );
    appRouteObserver.unsubscribe(this);
    _removeOverlay();
    _unlockLayoutIfNeeded();
    _browserLease?.release();
    final use = _webViewUse;
    if (use != null) {
      unawaited(
        _loadedOnce
            ? use.end(WebViewUseOutcome.loaded, reason: 'post_iframe_dispose')
            : use.end(WebViewUseOutcome.aborted),
      );
    }
    super.dispose();
  }

  URLRequest _initialRequest(IframeAttributes attrs) => URLRequest(
    url: WebUri(attrs.fullUrl),
    headers: {'Referer': AppConstants.baseUrl},
  );

  void _activateWindowsWebView() {
    if (_webViewActivated ||
        DynamicContentSuspensionService.instance.suspended) {
      return;
    }
    final lease = EmbeddedBrowserControllerPool.instance.tryAcquire(
      priority: EmbeddedBrowserPriority.iframe,
      onRevoked: _deactivateWindowsWebView,
    );
    if (lease == null) {
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text(S.current.common_pleaseWait)));
      return;
    }
    _browserLease = lease;
    setState(() => _webViewActivated = true);
  }

  void _deactivateWindowsWebView() {
    if (!mounted || !_webViewActivated) return;
    // release() 幂等:onRevoked 路径 pool 已释放,重复调用无害;
    // 挂起路径(_handleDynamicContentSuspension)必须在此归还,否则槽位泄漏。
    _browserLease?.release();
    _browserLease = null;
    setState(() {
      _webViewActivated = false;
      _isLoaded = false;
      _hasError = false;
    });
  }

  void _enterInteractMode() {
    setState(() => _interacting = true);
    _showOverlay();
  }

  void _onRenderProcessGone(RenderProcessGoneDetail detail) {
    WebViewRenderGone.report('iframe', detail);
    if (!mounted || _renderGone) return;
    _removeOverlay();
    _unlockLayoutIfNeeded();
    setState(() {
      _renderGone = true;
      _interacting = false;
      _isLoaded = false;
      _hasError = false;
    });
  }

  void _reloadAfterRenderGone() {
    if (!mounted) return;
    setState(() {
      _renderGone = false;
      _webViewGeneration++;
    });
  }

  /// 网页要开新窗口：叠一页内置浏览器承载它（同 WebViewPage 的弹窗）。
  /// 必须同步答应，新窗口的地址由网页随后加载进这一页
  Future<bool?> _openPopupPage(
    InAppWebViewController controller,
    CreateWindowAction action,
  ) async {
    if (!mounted) return false;
    unawaited(
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => WebViewPage(
            url: action.request.url?.toString() ?? '',
            allowPopups: true,
            windowId: action.windowId,
          ),
        ),
      ),
    );
    return true;
  }

  void _exitInteractMode() {
    _removeOverlay();
    setState(() => _interacting = false);
  }

  void _showOverlay() {
    _removeOverlay();
    _overlayEntry = OverlayEntry(
      builder: (context) => Positioned(
        top: MediaQuery.of(context).padding.top + 8,
        left: 0,
        right: 0,
        child: Center(
          child: Material(
            color: Colors.black87,
            borderRadius: BorderRadius.circular(20),
            child: InkWell(
              borderRadius: BorderRadius.circular(20),
              onTap: _exitInteractMode,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Symbols.close_rounded,
                      size: 18,
                      color: Colors.white,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      S.current.iframe_exitInteraction,
                      style: TextStyle(color: Colors.white, fontSize: 13),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    Overlay.of(context).insert(_overlayEntry!);
  }

  void _removeOverlay() {
    _overlayEntry?.remove();
    _overlayEntry = null;
  }

  @override
  Widget build(BuildContext context) {
    final attrs = widget.attributes;
    final theme = Theme.of(context);
    final deferWindowsWebView =
        !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;
    final showWebView = !deferWindowsWebView || _webViewActivated;

    // 构建内容 Widget
    Widget content = ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Stack(
        children: [
          // Windows 快速滚动时禁止自动创建 WebView2 Controller。用户明确
          // 点击后才加载，避免列表构建/回收堵住 Win32 平台消息线程。
          if (showWebView && !_renderGone)
            Offstage(
              offstage: _routeOverlayed,
              child: InAppWebView(
                key: ValueKey(_webViewGeneration),
                webViewEnvironment: deferWindowsWebView
                    ? WindowsWebViewEnvironmentService.instance.environment
                    : null,
                // 本站页面等 cookie 灌好再加载（见 [_webViewUse]）
                initialUrlRequest: _webViewUse == null
                    ? _initialRequest(attrs)
                    : null,
                initialSettings: _buildSettings(attrs),
                initialUserScripts: WebViewSettings.compatPolyfillScripts,
                onWebViewCreated: (controller) async {
                  WebViewSettings.registerJsErrorReporter(controller);
                  final use = _webViewUse;
                  if (use == null) return;
                  await use.ready;
                  if (!mounted) return;
                  await controller.loadUrl(urlRequest: _initialRequest(attrs));
                },
                onReceivedServerTrustAuthRequest: (_, challenge) =>
                    WebViewSettings.handleServerTrustAuthRequest(challenge),
                onRenderProcessGone: (_, detail) =>
                    _onRenderProcessGone(detail),
                // 允许 WebView 接收水平滑动手势
                gestureRecognizers: {
                  Factory<HorizontalDragGestureRecognizer>(
                    () => HorizontalDragGestureRecognizer(),
                  ),
                },
                onEnterFullscreen: (controller) {
                  _lockLayout();
                },
                onExitFullscreen: (controller) {
                  _unlockLayoutIfNeeded();
                },
                onLoadStart: (controller, url) {
                  if (mounted) {
                    setState(() {
                      _isLoaded = false;
                      _hasError = false;
                    });
                  }
                },
                onLoadStop: (controller, url) async {
                  _loadedOnce = true;
                  if (mounted) {
                    setState(() => _isLoaded = true);
                  }
                  // 注入 viewport meta 标签，确保内容正确缩放
                  await controller.evaluateJavascript(
                    source: '''
                    (function() {
                      var meta = document.querySelector('meta[name="viewport"]');
                      if (!meta) {
                        meta = document.createElement('meta');
                        meta.name = 'viewport';
                        document.head.appendChild(meta);
                      }
                      meta.content = 'width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no';
                    })();
                  ''',
                  );
                },
                onReceivedError: (controller, request, error) {
                  // 只有主框架加载失败才显示错误
                  // 忽略子资源（JS、图片、视频海报等）的加载错误
                  if (mounted && request.isForMainFrame == true) {
                    setState(() => _hasError = true);
                  }
                },
                // 拦截用户点击的链接，使用 WebViewPage 打开
                shouldOverrideUrlLoading: (controller, navigationAction) async {
                  // 只拦截用户主动点击的链接
                  if (navigationAction.navigationType !=
                      NavigationType.LINK_ACTIVATED) {
                    return NavigationActionPolicy.ALLOW;
                  }

                  final url = navigationAction.request.url?.toString();
                  if (url == null) {
                    return NavigationActionPolicy.ALLOW;
                  }

                  // 使用 WebViewPage 打开
                  if (mounted) {
                    WebViewPage.open(context, url);
                  }
                  return NavigationActionPolicy.CANCEL;
                },
                onCreateWindow: _allowPopups ? _openPopupPage : null,
              ),
            ),
          if (!showWebView)
            Positioned.fill(
              child: Material(
                color: theme.colorScheme.surfaceContainerHighest,
                child: InkWell(
                  onTap: _activateWindowsWebView,
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Symbols.play_circle_rounded,
                          size: 48,
                          color: theme.colorScheme.primary,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          attrs.title?.trim().isNotEmpty == true
                              ? attrs.title!
                              : Uri.tryParse(attrs.fullUrl)?.host ??
                                    attrs.fullUrl,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          if (_renderGone)
            Positioned.fill(
              child: ColoredBox(
                color: theme.colorScheme.surfaceContainerHighest,
                child: WebViewRenderGoneView(
                  compact: true,
                  onReload: _reloadAfterRenderGone,
                ),
              ),
            ),
          // 加载指示器
          if (showWebView && !_renderGone && !_isLoaded && !_hasError)
            Container(
              color: theme.colorScheme.surfaceContainerHighest,
              child: const Center(child: LoadingSpinner()),
            ),
          // 错误状态
          if (_hasError)
            Container(
              color: theme.colorScheme.surfaceContainerHighest,
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Symbols.error_rounded,
                      size: 48,
                      color: theme.colorScheme.error,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      S.current.common_loadFailed,
                      style: TextStyle(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          // 桌面平台：交互遮罩
          if (_needsInteractionMask && !_interacting && _isLoaded && !_hasError)
            Positioned.fill(
              child: GestureDetector(
                onTap: _enterInteractMode,
                child: Container(
                  color: Colors.black38,
                  child: const Center(
                    child: Icon(
                      Symbols.touch_app_rounded,
                      size: 48,
                      color: Colors.white70,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );

    // 始终使用响应式宽高比布局，忽略固定像素尺寸
    // 这样可以适配不同屏幕尺寸，避免在小屏幕上溢出或在大屏幕上显得太小
    Widget sizedContent;

    // 特殊情况：如果只有固定高度（没有宽度或宽度是百分比），使用固定高度
    // 例如：width="100%" height="111"
    if (attrs.height != null && attrs.height! > 0 && attrs.width == null) {
      sizedContent = SizedBox(
        width: double.infinity,
        height: attrs.height,
        child: content,
      );
    } else {
      // 其他情况使用宽高比
      sizedContent = AspectRatio(
        aspectRatio: attrs.aspectRatio,
        child: content,
      );
    }

    final miniAppId = _miniAppId;
    if (miniAppId == null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: sizedContent,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(padding: const EdgeInsets.only(top: 8), child: sizedContent),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            onPressed: () => MiniAppPage.open(context, miniAppId),
            icon: const Icon(Symbols.open_in_full_rounded, size: 18),
            label: Text(context.l10n.miniApp_openFullscreen),
            style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
          ),
        ),
      ],
    );
  }

  InAppWebViewSettings _buildSettings(IframeAttributes attrs) {
    return InAppWebViewSettings(
      // User-Agent
      userAgent: AppConstants.webViewUserAgentOverride,

      // JavaScript（根据 sandbox 属性决定）
      javaScriptEnabled: attrs.allowScripts,

      // 媒体播放
      mediaPlaybackRequiresUserGesture: !attrs.allowAutoplay,
      allowsInlineMediaPlayback: true,

      // 全屏（根据 allowfullscreen 属性决定）
      iframeAllowFullscreen: attrs.allowFullscreen,

      // 外观
      transparentBackground: true,

      // 新窗口：网页 window.open 开的页面叠一页内置浏览器承载（见 [_openPopupPage]）。
      // 不接的话 Android 会在这个嵌入框里直接换成新页面，帖子里的应用就没了
      supportMultipleWindows: _allowPopups,
      javaScriptCanOpenWindowsAutomatically: _allowPopups,

      // 性能
      useHybridComposition: true,

      // 内容模式
      preferredContentMode: UserPreferredContentMode.RECOMMENDED,

      // 允许混合内容和第三方 cookies
      mixedContentMode: MixedContentMode.MIXED_CONTENT_ALWAYS_ALLOW,
      thirdPartyCookiesEnabled: true,

      // 渲染进程没了由我们认领，否则 Android 连 App 一起杀
      useOnRenderProcessGone: true,
    );
  }

  void _lockLayout() {
    if (_didLockLayout) return;
    _didLockLayout = true;
    LayoutLock.acquire();
  }

  void _unlockLayoutIfNeeded() {
    if (!_didLockLayout) return;
    _didLockLayout = false;
    LayoutLock.release();
  }
}
