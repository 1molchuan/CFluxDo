import 'package:flutter/material.dart';

import '../../config/forum_site.dart';
import '../../l10n/s.dart';
import '../../services/site_context.dart';
import '../../services/site_switch_service.dart';
import '../../services/toast_service.dart';
import '../../theme/vscode_theme.dart';

/// 只提交站点选择，不在旧引擎中变更当前站点或认证状态。
class SiteSwitchButton extends StatelessWidget {
  const SiteSwitchButton({super.key, this.extended = false});

  final bool extended;

  Future<void> _switchTo(ForumSite target) async {
    final service = SiteSwitchService.instance;
    if (target == SiteContext.current || service.isSwitching.value) return;
    try {
      await service.switchTo(target);
    } catch (_) {
      // 不展示平台异常，避免将认证信息或本地路径带入提示。
      ToastService.showError(S.current.common_switchSiteFailed);
    }
  }

  Widget _logo(ForumSite site) => Image.asset(
    site.logoAsset,
    width: 28,
    height: 28,
    fit: BoxFit.contain,
    excludeFromSemantics: true,
  );

  @override
  Widget build(BuildContext context) {
    final current = SiteContext.current;
    final l10n = context.l10n;
    final vscode = VscodeTokens.maybeOf(context);
    return ValueListenableBuilder<bool>(
      valueListenable: SiteSwitchService.instance.isSwitching,
      builder: (context, switching, _) {
        final label = switching
            ? l10n.common_switchingSite
            : l10n.common_switchSite;
        return PopupMenuButton<ForumSite>(
          enabled: !switching,
          tooltip: '$label · ${current.name}',
          initialValue: current,
          onSelected: _switchTo,
          itemBuilder: (context) => [
            for (final site in ForumSite.values)
              PopupMenuItem<ForumSite>(
                value: site,
                child: Semantics(
                  selected: site == current,
                  child: Row(
                    children: [
                      _logo(site),
                      const SizedBox(width: 12),
                      Expanded(child: Text(site.name)),
                      const SizedBox(width: 16),
                      if (site == current)
                        const ExcludeSemantics(child: Icon(Icons.check)),
                    ],
                  ),
                ),
              ),
          ],
          child: Semantics(
            button: true,
            enabled: !switching,
            label: '$label · ${current.name}',
            excludeSemantics: true,
            child: vscode != null
                ? SizedBox(
                    width: 52,
                    height: 46,
                    child: Center(
                      child: switching
                          ? SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 1.5,
                                color: vscode.muted,
                              ),
                            )
                          : SizedBox.square(
                              dimension: 28,
                              child: Stack(
                                alignment: Alignment.center,
                                children: [
                                  Icon(Icons.language_outlined, size: 22, color: vscode.muted),
                                  Positioned(
                                    right: -1,
                                    bottom: -1,
                                    child: ColoredBox(
                                      color: vscode.panel,
                                      child: Icon(Icons.unfold_more, size: 11, color: vscode.muted),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                    ),
                  )
                : Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (switching)
                    const SizedBox(
                      width: 28,
                      height: 28,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  else
                    _logo(current),
                  if (extended) ...[
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(current.name, overflow: TextOverflow.ellipsis),
                    ),
                    const SizedBox(width: 4),
                    const Icon(Icons.expand_more, size: 16),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
