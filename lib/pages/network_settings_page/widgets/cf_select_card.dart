import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:m3e_ui/m3e_ui.dart';

import '../../../l10n/s.dart';
import '../../../services/network/doh/cfhub_probe_auth_service.dart';
import '../../../services/network/doh/network_settings_service.dart';
import '../../../services/network/proxy/proxy_settings_service.dart';
import '../../../services/toast_service.dart';
import '../custom_nodes_page.dart';
import 'cf_select_privacy_dialog.dart';
import 'ip_family_card.dart' show CardTitleRow;

/// 节点优选卡片（高级设置）
///
/// 1.1 起 App 自己在 Cloudflare 共享池里测速选节点，atlas 节点表一起参与竞速。
/// 这里放优选方式（本地优选 + atlas / 只用 atlas 池）、自定义节点入口、「帮助优选」
/// （向 cfhub 分享测量结果）开关和隐私说明入口；当前节点、重新优选在主页面的连接状态卡里。
class CfSelectCard extends StatefulWidget {
  const CfSelectCard({super.key});

  @override
  State<CfSelectCard> createState() => _CfSelectCardState();
}

class _CfSelectCardState extends State<CfSelectCard> {
  /// 正在走 cfhub 授权流程（期间禁用开关、显示进度）
  bool _enablingShare = false;

  /// 上次看到的 rejectedNotifier 值，变化才弹「授权已失效」
  late int _lastRejected;

  @override
  void initState() {
    super.initState();
    final rejected = CfhubProbeAuthService.instance.rejectedNotifier;
    _lastRejected = rejected.value;
    rejected.addListener(_onRejectedChanged);
  }

  @override
  void dispose() {
    CfhubProbeAuthService.instance.rejectedNotifier.removeListener(
      _onRejectedChanged,
    );
    super.dispose();
  }

  void _onRejectedChanged() {
    final now = CfhubProbeAuthService.instance.rejectedNotifier.value;
    if (now == _lastRejected) return;
    _lastRejected = now;
    ToastService.showError(S.current.cfSelect_shareRevoked);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final service = NetworkSettingsService.instance;

    return AnimatedBuilder(
      animation: Listenable.merge([
        service.notifier,
        service.selectStatusNotifier,
        ProxySettingsService.instance.notifier,
      ]),
      builder: (context, _) {
        final settings = service.current;
        return SegmentedCardGroup(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
              child: _buildModeSelector(theme, service, settings.selectMode),
            ),
            // 自定义节点：两种优选方式下都优先于池里的节点
            ListTile(
              key: const ValueKey('cf-select-custom-nodes'),
              leading: Icon(
                Symbols.push_pin_rounded,
                fill: settings.customNodes.isEmpty ? 0 : 1,
                color: settings.customNodes.isEmpty
                    ? null
                    : theme.colorScheme.primary,
              ),
              title: Text(context.l10n.customNodes_title),
              subtitle: Text(
                customNodesSummary(
                  context.l10n,
                  settings.customNodes,
                  service.selectorEligible
                      ? service.selectStatusNotifier.value
                      : null,
                ),
              ),
              trailing: const Icon(Symbols.chevron_right_rounded, size: 20),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const CustomNodesPage()),
              ),
            ),
            _buildShareTile(theme, settings),
            ListTile(
              leading: const Icon(Symbols.policy_rounded),
              title: Text(context.l10n.cfSelect_viewPrivacy),
              trailing: const Icon(Symbols.chevron_right_rounded, size: 20),
              onTap: () =>
                  showCfSelectPrivacyDialog(context, firstLaunch: false),
            ),
          ],
        );
      },
    );
  }

  // ---- 优选方式 ----

  Widget _buildModeSelector(
    ThemeData theme,
    NetworkSettingsService service,
    CfSelectMode mode,
  ) {
    final l10n = context.l10n;
    final cs = theme.colorScheme;
    // 上游代理开启 / 加速关闭 / 网关模式关闭时 Rust 侧不做优选，选了也不生效，说明原因
    final String? ineligible = service.selectorEligible
        ? null
        : ProxySettingsService.instance.current.isValid
        ? l10n.cfSelect_disabledByProxy
        : !service.current.dohEnabled
        ? l10n.cfSelect_disabledByDoh
        : (Platform.isAndroid || Platform.isLinux || Platform.isWindows)
        ? l10n.netStatus_noSelectGateway
        : l10n.netStatus_noSelectPlatform;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CardTitleRow(
          icon: Symbols.alt_route_rounded,
          title: l10n.cfSelect_modeTitle,
        ),
        const SizedBox(height: 10),
        SizedBox(
          width: double.infinity,
          child: M3eButtonGroup<CfSelectMode>(
            itemPadding: const EdgeInsets.symmetric(
              horizontal: 10,
              vertical: 10,
            ),
            items: [
              M3eButtonGroupItem(
                value: CfSelectMode.localAtlas,
                label: Text(l10n.cfSelect_modeLocalAtlas),
              ),
              M3eButtonGroupItem(
                value: CfSelectMode.atlasOnly,
                label: Text(l10n.cfSelect_modeAtlasOnly),
              ),
            ],
            selected: mode,
            onSelected: (value) => unawaited(service.setSelectMode(value)),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          switch (mode) {
            CfSelectMode.localAtlas => l10n.cfSelect_modeLocalAtlasDesc,
            CfSelectMode.atlasOnly => l10n.cfSelect_modeAtlasOnlyDesc,
          },
          style: theme.textTheme.bodySmall?.copyWith(
            color: cs.onSurfaceVariant,
          ),
        ),
        if (ineligible != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(
              children: [
                Icon(Symbols.block_rounded, size: 14, color: cs.tertiary),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    ineligible,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: cs.tertiary,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  // ---- 帮助优选 ----

  Widget _buildShareTile(ThemeData theme, NetworkSettings settings) {
    final l10n = context.l10n;
    final on = settings.shareMeasurements;
    final authorized = on && CfhubProbeAuthService.instance.isAuthorized;

    return SwitchListTile(
      secondary: _enablingShare
          ? SizedBox(
              width: 24,
              height: 24,
              child: Padding(
                padding: const EdgeInsets.all(2),
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: theme.colorScheme.primary,
                ),
              ),
            )
          : Icon(
              Symbols.volunteer_activism_rounded,
              fill: on ? 1 : 0,
              color: on ? theme.colorScheme.primary : null,
            ),
      title: Text(l10n.cfSelect_share),
      subtitle: Text(
        authorized ? l10n.cfSelect_shareAuthorized : l10n.cfSelect_shareDesc,
      ),
      value: on,
      onChanged: _enablingShare ? null : _onShareChanged,
    );
  }

  Future<void> _onShareChanged(bool value) async {
    final auth = CfhubProbeAuthService.instance;
    if (!value) {
      // 关闭立即生效并作废授权
      await auth.disable();
      if (mounted) setState(() {});
      return;
    }
    setState(() => _enablingShare = true);
    try {
      // 走 linux.do Connect 授权 cfhub；成功与否由服务层落盘 shareMeasurements
      final result = await auth.enable();
      showCfhubEnableResultToast(result);
    } catch (e) {
      ToastService.showError(S.current.common_operationFailed('$e'));
    } finally {
      if (mounted) setState(() => _enablingShare = false);
    }
  }
}
