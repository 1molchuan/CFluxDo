import 'package:flutter/material.dart';

import '../../config/forum_site.dart';
import '../../l10n/s.dart';
import '../../services/site_context.dart';
import '../../services/site_switch_service.dart';
import '../../services/toast_service.dart';
import '../../theme/mojian_theme.dart';

/// 只提交站点选择，不在旧引擎中变更当前站点或认证状态。
///
/// 三种形态：
/// - 默认：只有站点图标（侧栏收起态、启动页）
/// - [extended]：图标 + 站名 + ⌄（宽侧栏、手机「我的」页顶栏左侧）
/// - [SiteSwitchButton.capsule]：带底色的小胶囊（图标 + ⌄），放手机首页工具栏
///
/// 手机上不再给它单独留一行：换站是低频操作，常驻一行白占所有页面的顶部高度。
class SiteSwitchButton extends StatelessWidget {
  const SiteSwitchButton({super.key, this.extended = false}) : _capsule = false;

  const SiteSwitchButton.capsule({super.key})
    : extended = false,
      _capsule = true;

  final bool extended;
  final bool _capsule;

  /// 站点图标是「白色圆角方块里套一个圆」的应用图标形状，圆约占边长的 0.89。
  /// 胶囊里只要里面那个圆：放大后按圆裁掉外圈白边。
  static const double _logoCircleRatio = 0.89;

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

  Widget _roundLogo(ForumSite site, double size) {
    final full = size / _logoCircleRatio;
    return ClipOval(
      child: SizedBox.square(
        dimension: size,
        child: OverflowBox(
          maxWidth: full,
          maxHeight: full,
          child: Image.asset(
            site.logoAsset,
            width: full,
            height: full,
            fit: BoxFit.contain,
            excludeFromSemantics: true,
          ),
        ),
      ),
    );
  }

  List<PopupMenuEntry<ForumSite>> _menuItems(ForumSite current) => [
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
  ];

  @override
  Widget build(BuildContext context) {
    final current = SiteContext.current;
    final l10n = context.l10n;
    return ValueListenableBuilder<bool>(
      valueListenable: SiteSwitchService.instance.isSwitching,
      builder: (context, switching, _) {
        final label = switching
            ? l10n.common_switchingSite
            : l10n.common_switchSite;
        final semanticLabel = '$label · ${current.name}';
        if (_capsule) {
          return _buildCapsule(context, current, switching, semanticLabel);
        }
        return PopupMenuButton<ForumSite>(
          enabled: !switching,
          tooltip: semanticLabel,
          initialValue: current,
          onSelected: _switchTo,
          itemBuilder: (context) => _menuItems(current),
          child: Semantics(
            button: true,
            enabled: !switching,
            label: semanticLabel,
            excludeSemantics: true,
            child: Padding(
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
                      child: Text(
                        current.name,
                        overflow: TextOverflow.ellipsis,
                      ),
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

  /// 32 高的小胶囊：底色与形状跟首页工具栏里其它药丸一致
  /// （经典 = 浅灰全圆角，墨笺 = 纸色细线框小圆角）。
  Widget _buildCapsule(
    BuildContext context,
    ForumSite current,
    bool switching,
    String semanticLabel,
  ) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final mj = theme.extension<MojianTokens>();
    final radius = BorderRadius.circular(mj != null ? 4 : 16);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Material(
        key: const ValueKey('site-switch-capsule'),
        color: mj?.paper2 ?? scheme.surfaceContainerHigh,
        shape: RoundedRectangleBorder(
          borderRadius: radius,
          side: mj != null ? BorderSide(color: mj.ruleStrong) : BorderSide.none,
        ),
        clipBehavior: Clip.antiAlias,
        child: PopupMenuButton<ForumSite>(
          enabled: !switching,
          tooltip: semanticLabel,
          initialValue: current,
          onSelected: _switchTo,
          position: PopupMenuPosition.under,
          borderRadius: radius,
          itemBuilder: (context) => _menuItems(current),
          child: Semantics(
            button: true,
            enabled: !switching,
            label: semanticLabel,
            excludeSemantics: true,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(6, 6, 4, 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (switching)
                    const SizedBox.square(
                      dimension: 20,
                      child: Padding(
                        padding: EdgeInsets.all(2),
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  else
                    _roundLogo(current, 20),
                  const SizedBox(width: 2),
                  Icon(
                    Icons.expand_more,
                    size: 18,
                    color: mj?.ink2 ?? scheme.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
