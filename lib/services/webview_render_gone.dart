import 'package:app_icons/app_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../l10n/s.dart';
import 'log/log_writer.dart';

/// WebView 渲染进程没了（崩溃，或在后台时被系统回收内存杀掉）。
///
/// Android 8+ 上同一个 App 的 WebView 通常共用一个渲染进程：它一没，每个
/// 活着的 WebView 都会收到 onRenderProcessGone；只要有一个没认领（设置里没开
/// `useOnRenderProcessGone`），系统就把整个 App 一起杀掉——上游 #428 海信
/// 墨水屏「弹出安全验证就重启」就是这样。所以每个 WebView 都开
/// `useOnRenderProcessGone`，回调里记日志并丢掉这个实例：认领之后它就不能再
/// 用了，页面要从树上摘掉重建，后台任务按失败收场、走各自的兜底。
abstract final class WebViewRenderGone {
  static void report(String source, RenderProcessGoneDetail detail) {
    debugPrint('[WebView] 渲染进程退出 source=$source didCrash=${detail.didCrash}');
    LogWriter.instance.write({
      'timestamp': DateTime.now().toIso8601String(),
      'level': 'warning',
      'type': 'webview',
      'event': 'webview_render_process_gone',
      'message': detail.didCrash ? 'WebView 渲染进程崩溃' : 'WebView 渲染进程被系统回收',
      'source': source,
      'didCrash': detail.didCrash,
      'rendererPriorityAtExit': detail.rendererPriorityAtExit?.toNativeValue(),
    });
  }
}

/// 可见 WebView 的渲染进程兜底：进程没了就把 WebView 从树上摘掉，换成
/// [WebViewRenderGoneView]；重新加载时用 [webViewGeneration] 当 key 建新实例。
mixin WebViewRenderGoneState<T extends StatefulWidget> on State<T> {
  bool webViewRenderGone = false;
  int webViewGeneration = 0;

  /// 子类在这里丢掉旧 controller 等引用（已在 setState 里调用）
  void onWebViewDiscarded() {}

  void handleWebViewRenderGone(String source, RenderProcessGoneDetail detail) {
    WebViewRenderGone.report(source, detail);
    if (!mounted || webViewRenderGone) return;
    setState(() {
      webViewRenderGone = true;
      onWebViewDiscarded();
    });
  }

  void reloadAfterRenderGone() {
    if (!mounted) return;
    setState(() {
      webViewRenderGone = false;
      webViewGeneration++;
    });
  }
}

/// WebView 渲染进程退出后的占位：说明 + 重新加载（[onReload] 为空时不给按钮）
class WebViewRenderGoneView extends StatelessWidget {
  const WebViewRenderGoneView({super.key, this.onReload, this.compact = false});

  final VoidCallback? onReload;

  /// 帖子里的内嵌页面等小区域：只留一行提示和按钮
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final reload = onReload == null
        ? null
        : FilledButton.tonalIcon(
            onPressed: onReload,
            icon: const Icon(Symbols.refresh_rounded, size: 18),
            label: Text(l10n.webview_renderGoneReload),
          );
    if (compact) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                l10n.webview_renderGoneTitle,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
              if (reload != null) ...[const SizedBox(height: 8), reload],
            ],
          ),
        ),
      );
    }
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Symbols.sentiment_dissatisfied_rounded,
              size: 48,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 16),
            Text(
              l10n.webview_renderGoneTitle,
              style: theme.textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              l10n.webview_renderGoneMessage,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
            if (reload != null) ...[const SizedBox(height: 20), reload],
          ],
        ),
      ),
    );
  }
}
