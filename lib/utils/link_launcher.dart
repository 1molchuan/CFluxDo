import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config/site_customization.dart';
import '../constants.dart';
import '../pages/chat/channel/chat_channel_page.dart';
import '../pages/image_viewer_page.dart';
import '../pages/webview_page.dart';
import '../providers/preferences_provider.dart';
import '../providers/category_provider.dart';
import '../providers/selected_topic_provider.dart';
import '../l10n/s.dart';
import '../services/discourse/discourse_service.dart';
import '../config/forum_site.dart';
import '../services/site_context.dart';
import '../services/site_switch_service.dart';
import '../services/toast_service.dart';
import '../widgets/common/external_link_confirm_dialog.dart';
import '../widgets/content/discourse_html_content/image_utils.dart';
import '../widgets/layout/home_workspace_scope.dart';
import 'discourse_url_parser.dart';
import 'link_security.dart';
import 'url_helper.dart';

const _browserChannel = MethodChannel('com.github.lingyan000.fluxdo/browser');

/// 交给系统打开 [uri]（浏览器、邮件客户端、下载等），返回是否打开了。
///
/// Linux 不先问 `canLaunchUrl`：它查的是本机注册的默认程序，Flatpak 沙箱
/// 里没有任何注册，永远回答「打不开」，以前就卡在这一步（Issue #2）。
/// 真正打开用的 `gtk_show_uri` 在沙箱里会走 XDG 门户交给宿主机，所以直接
/// 调；还不行再试 `xdg-open`（Flatpak 运行时里它也转发给门户）。
Future<bool> openWithSystem(Uri uri) async {
  if (!Platform.isLinux) {
    if (!await canLaunchUrl(uri)) return false;
    return launchUrl(uri, mode: LaunchMode.externalApplication);
  }
  try {
    if (await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      return true;
    }
  } catch (e) {
    debugPrint('[LinkLauncher] launchUrl 失败，改用 xdg-open: $e');
  }
  try {
    final result = await Process.run('xdg-open', [uri.toString()]);
    return result.exitCode == 0;
  } catch (e) {
    debugPrint('[LinkLauncher] xdg-open 失败: $e');
    return false;
  }
}

/// 检查 URL 是否属于当前论坛主域路由，不包含子域服务。
bool isInternalUrl(Uri uri) {
  if (ForumSite.fromUri(uri) != SiteContext.current) return false;
  if (uri.hasPort && uri.port != (uri.scheme == 'https' ? 443 : 80)) {
    return false;
  }

  return UrlHelper.samePrefix(uri.toString());
}

/// 检查 URL 是否属于站点内部链接（字符串版本，支持相对路径）
bool isInternalUrlString(String url) {
  final uri = Uri.tryParse(UrlHelper.resolveUrl(url));
  if (uri == null) return false;
  return isInternalUrl(uri);
}

bool _isUploadLink(String url) {
  return url.contains('/uploads/') ||
      url.contains('/secure-uploads/') ||
      url.contains('/secure-media-uploads/');
}

/// 严格按扩展名判断图片链接(不像 [DiscourseImageUtils.isImageUrl] 那样
/// 靠路径包含 `/uploads/`/`/original/` 兜底——那个宽松判据是为了在 DOM
/// 里找 lightbox 链接,误判无害;这里要拦截"点了就直接开查看器"的链接,
/// 误判会把 PDF/zip 等非图片附件也当图片打开,必须严格。
bool _isImageLinkUrl(String url) {
  final path = Uri.tryParse(url)?.path.toLowerCase() ?? url.toLowerCase();
  const exts = ['.jpg', '.jpeg', '.png', '.gif', '.webp', '.avif'];
  return exts.any(path.endsWith);
}

/// 打开外部链接
///
/// 如果启用了链接安全检查，会根据链接风险等级弹出确认对话框，
/// 由用户选择使用内置浏览器还是系统浏览器；未弹框（信任/内部链接，
/// 或未启用离站确认）时按「外部链接使用内置浏览器」偏好分流
Future<void> launchExternalLink(BuildContext context, String url) async {
  if (url.isEmpty) return;
  final uri = Uri.tryParse(url);
  if (uri == null) return;

  final prefs = ProviderScope.containerOf(
    context,
    listen: false,
  ).read(preferencesProvider);

  // 链接安全检查
  ExternalLinkOpenChoice? explicitChoice;
  final config = AppConstants.siteCustomization.linkSecurityConfig;
  if (config != null && config.enableExitConfirmation) {
    final riskLevel = LinkSecurity.checkUrl(url, config);

    switch (riskLevel) {
      case LinkRiskLevel.internal:
      case LinkRiskLevel.trusted:
        // 内部或信任链接，直接打开
        break;
      case LinkRiskLevel.blocked:
        // 阻止链接，显示阻止提示
        await showLinkBlockedDialog(context, url);
        return;
      case LinkRiskLevel.normal:
      case LinkRiskLevel.risky:
      case LinkRiskLevel.dangerous:
        // 需要确认的链接，显示确认对话框，由用户选择打开方式
        explicitChoice = await showExternalLinkConfirmDialog(
          context,
          url,
          riskLevel,
          preferInApp: prefs.openExternalLinksInAppBrowser,
        );
        if (explicitChoice == null) return;
        break;
    }
  }

  // 安全确认对话框关闭时，原帖子/页面可能已经被滚动回收或导航销毁。
  if (!context.mounted) return;

  // 确认弹层中已显式选择「内置浏览器」：不经偏好，直接进内置 WebView
  if (explicitChoice == ExternalLinkOpenChoice.inAppBrowser) {
    WebViewPage.open(context, url);
    return;
  }

  // 确认弹层中已显式选择「系统浏览器」：尊重本次选择，忽略偏好
  final preferInApp = explicitChoice == ExternalLinkOpenChoice.systemBrowser
      ? false
      : prefs.openExternalLinksInAppBrowser;

  if (preferInApp && (uri.scheme == 'http' || uri.scheme == 'https')) {
    WebViewPage.open(context, url);
    return;
  }

  if (!await openWithSystem(uri)) {
    ToastService.showError(S.current.common_cannotOpenBrowser);
  }
}

/// 打开内容中的链接（统一入口）
///
/// 处理所有类型的链接：
/// - 用户链接 /u/username → 打开用户页面
/// - 话题链接 /t/topic/123 → 调用 onInternalLinkTap 或用 WebView 打开
/// - 图片直链（站点域名/CDN/S3 CDN）→ 内置查看器直接打开，对齐网页端
/// - 附件链接 /uploads/ → 外部浏览器打开
/// - 站点内部链接（主域名或子域名）→ 内置浏览器
/// - Email 链接 → 外部邮件客户端
/// - 外部链接 → 根据用户偏好决定
Future<void> launchContentLink(
  BuildContext context,
  String url, {
  void Function(int topicId, String? topicSlug, int? postNumber)?
  onInternalLinkTap,
  void Function(String url)? onDownloadAttachment,
}) async {
  if (url.isEmpty) return;
  if (url.startsWith('//')) url = UrlHelper.resolveUrl(url);
  if (url.startsWith('upload://')) {
    url = await DiscourseService().resolveShortUrlForLink(url) ?? url;
    // 短链解析期间列表项可能已离开缓存范围并被销毁，不能再使用旧 context。
    if (!context.mounted) return;
  }
  // 相对链接必须由当前站解析；已知另一站主域先切站再重放导航。
  final targetUri = Uri.tryParse(url);
  final targetSite = targetUri == null ? null : ForumSite.fromUri(targetUri);
  if (targetSite != null && targetSite != SiteContext.current) {
    await SiteSwitchService.instance.switchTo(
      targetSite,
      openUrl: targetUri!.replace(scheme: 'https', port: 443),
    );
    return;
  }

  // 1. 识别用户链接 /u/username
  final userInfo = DiscourseUrlParser.parseUser(url);
  if (userInfo != null && isInternalUrlString(url)) {
    EmbeddedStackScope.openProfile(context, userInfo.username);
    return;
  }

  // 首页平行视界中的站点首页、分类和标签链接直接替换左栏，不再打开
  // WebView。正文链接与话题头部 Badge 使用同一套行为。
  final workspace = HomeWorkspaceScope.maybeOf(context);
  if (workspace != null && isInternalUrlString(url)) {
    if (DiscourseUrlParser.isHomepage(url)) {
      workspace.onShowFeed();
      return;
    }
    final categoryInfo = DiscourseUrlParser.parseCategory(url);
    if (categoryInfo != null) {
      final container = ProviderScope.containerOf(context, listen: false);
      final category = container
          .read(categoryMapProvider)
          .value?[categoryInfo.categoryId];
      if (category != null) {
        workspace.onShowCategory(category);
        return;
      }
    }
    final tag = DiscourseUrlParser.parseTag(url);
    if (tag != null && tag.isNotEmpty) {
      workspace.onShowTag(tag);
      return;
    }
  }

  // 2. 聊天链接(/chat/c/...):进原生频道页,消息 id 作定位锚点。
  //    必须在话题分支之前——thread 形态 /chat/c/-/:cid/t/:tid/:mid 里的
  //    "/t/数字" 会被话题正则误命中抢走
  final chatInfo = DiscourseUrlParser.parseChat(url);
  if (chatInfo != null && isInternalUrlString(url)) {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ChatChannelPage(
          channelId: chatInfo.channelId,
          threadId: chatInfo.threadId,
          initialMessageId: chatInfo.messageId,
        ),
      ),
    );
    return;
  }

  // 3. 解析话题链接
  final topicInfo = DiscourseUrlParser.parseTopic(url);
  if (topicInfo != null && isInternalUrlString(url)) {
    if (onInternalLinkTap != null) {
      onInternalLinkTap(
        topicInfo.topicId,
        topicInfo.slug,
        topicInfo.postNumber,
      );
      return;
    }
    // 没有回调时用 WebView 打开
    final fullUrl = UrlHelper.resolveUrl(url);
    WebViewPage.open(context, fullUrl);
    return;
  }

  // 3. 图片直链(站点自己的域名/CDN/S3 CDN)→ 直接用内置查看器打开,
  //    与网页端一致(点图直接看大图,不当"外部链接"走离站确认弹窗)。
  //    只信任站点自己配置的域名——不是随便一个图片后缀的外链都放行。
  if (_isImageLinkUrl(url)) {
    final fullUrl = UrlHelper.resolveUrlWithCdn(
      isInternalUrlString(url) ? UrlHelper.resolveUrl(url) : url,
    );
    final uri = Uri.tryParse(fullUrl);
    if (uri != null && UrlHelper.isTrustedImageHost(uri)) {
      await ImageViewerPage.open(
        context,
        DiscourseImageUtils.getOriginalUrl(fullUrl),
      );
      return;
    }
  }

  // 4. 附件链接：优先使用内置下载，回退外部浏览器
  if (_isUploadLink(url) && isInternalUrlString(url)) {
    final fullUrl = UrlHelper.resolveUrl(url);
    if (onDownloadAttachment != null) {
      onDownloadAttachment(fullUrl);
    } else {
      final uri = Uri.tryParse(fullUrl);
      if (uri != null) await openWithSystem(uri);
    }
    return;
  }

  // 5. Email 链接
  if (url.startsWith('mailto:')) {
    final uri = Uri.tryParse(url);
    if (uri != null) await openWithSystem(uri);
    return;
  }

  // 6. 站点内部链接（主域名或子域名、相对路径）→ 内置浏览器
  if (isInternalUrlString(url)) {
    final fullUrl = UrlHelper.resolveUrl(url);
    WebViewPage.open(context, fullUrl);
    return;
  }

  // 7. 外部链接 → 根据用户偏好决定
  await launchExternalLink(context, url);
}

/// 强制在外部浏览器打开链接，绕过 App Links
///
/// 在 Android 上通过原生代码排除自己的应用，直接用外部浏览器打开，
/// 避免被应用的 intent-filter 拦截导致链接又回到应用本身。
Future<bool> launchInExternalBrowser(String url) async {
  final uri = Uri.tryParse(url);
  if (uri == null) return false;

  if (Platform.isAndroid) {
    try {
      final result = await _browserChannel.invokeMethod<bool>('openInBrowser', {
        'url': url,
      });
      return result ?? false;
    } catch (e) {
      debugPrint('[LinkLauncher] Failed to launch browser: $e');
      // 回退到 url_launcher
      return openWithSystem(uri);
    }
  }
  return openWithSystem(uri);
}
