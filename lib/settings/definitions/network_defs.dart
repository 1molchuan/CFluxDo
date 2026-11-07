import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';

import '../../l10n/s.dart';
import '../../pages/app_logs_page.dart';
import '../../pages/network_settings_page/network_advanced_settings_page.dart';
import '../../pages/network_settings_page/widgets/cf_select_card.dart';
import '../../pages/network_settings_page/widgets/connection_status_card.dart';
import '../../pages/network_settings_page/widgets/doh_settings_card.dart';
import '../../pages/network_settings_page/widgets/engine_card.dart';
import '../../pages/network_settings_page/widgets/eruda_card.dart';
import '../../pages/network_settings_page/widgets/http_proxy_card.dart';
import '../../pages/network_settings_page/widgets/ip_family_card.dart';
import '../../pages/network_settings_page/widgets/rate_limit_card.dart';
import '../../pages/network_settings_page/widgets/vpn_auto_toggle_card.dart';
import '../../providers/preferences_provider.dart';
import '../../providers/theme_provider.dart';
import '../../services/cf_challenge_service.dart';
import '../../services/toast_service.dart';
import '../settings_model.dart';

import 'package:m3e_ui/m3e_ui.dart';

/// 网络设置（主页面）
///
/// 只放大多数人会看、会改的：连接状态、IP 协议、引擎预设、人机验证、代理与 VPN；
/// 其余（节点优选方式、加速总开关、DNS、引擎逐项组合、限流、上传、调试）
/// 收进 [buildNetworkAdvancedGroups]。
List<SettingsGroup> buildNetworkGroups(BuildContext context) {
  final l10n = context.l10n;
  return [
    // 连接：状态 + IP 协议 + 引擎预设
    SettingsGroup(
      title: l10n.networkSettings_connection,
      icon: Symbols.alt_route_rounded,
      wrapInCard: false,
      items: [
        CustomModel(
          id: 'connectionStatus',
          title: l10n.netStatus_title,
          subtitle: l10n.netStatus_searchDesc,
          builder: (_, _) => const ConnectionStatusCard(),
        ),
        CustomModel(
          id: 'ipFamily',
          title: l10n.cfSelect_ipFamily,
          subtitle: 'IPv6 · IPv4',
          builder: (_, _) => const IpFamilyCard(),
        ),
        CustomModel(
          id: 'engine',
          title: l10n.networkSettings_engine,
          subtitle:
              '${l10n.enginePreset_standard} · ${l10n.enginePreset_performance} · ${l10n.enginePreset_compat}',
          builder: (_, _) => const EngineCard(),
        ),
      ],
    ),

    // 人机验证
    SettingsGroup(
      title: l10n.networkSettings_cfVerify,
      icon: Symbols.shield_rounded,
      items: [
        SwitchModel(
          id: 'autoCfChallenge',
          title: l10n.cfVerify_autoTitle,
          subtitle: l10n.cfVerify_autoDesc,
          icon: Symbols.shield_rounded,
          getValue: (ref) => ref.watch(preferencesProvider).autoCfChallenge,
          onChanged: (ref, value) =>
              ref.read(preferencesProvider.notifier).setAutoCfChallenge(value),
        ),
        ActionModel(
          id: 'cfVerify',
          title: l10n.cfVerify_manualTitle,
          subtitle: l10n.cfVerify_manualDesc,
          wrapSubtitle: true,
          icon: Symbols.verified_user_rounded,
          onTap: (context, _) => _manualVerify(context),
        ),
      ],
    ),

    // 代理与 VPN
    SettingsGroup(
      title: l10n.networkSettings_proxyVpn,
      icon: Symbols.vpn_key_rounded,
      wrapInCard: false,
      items: [
        CustomModel(
          id: 'httpProxy',
          title: l10n.httpProxy_title,
          subtitle: l10n.httpProxy_disabledDesc,
          builder: (_, _) => const HttpProxyCard(),
        ),
        CustomModel(
          id: 'vpnAutoToggle',
          title: l10n.vpnToggle_title,
          subtitle: l10n.vpnToggle_subtitle,
          builder: (_, _) => const VpnAutoToggleCard(),
        ),
      ],
    ),

    // 更多：高级设置与日志
    SettingsGroup(
      title: l10n.networkSettings_more,
      icon: Symbols.more_horiz_rounded,
      items: [
        ActionModel(
          id: 'networkAdvanced',
          title: l10n.networkSettings_advancedEntry,
          subtitle: l10n.networkSettings_advancedEntryDesc,
          wrapSubtitle: true,
          icon: Symbols.tune_rounded,
          onTap: (context, _) => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => const NetworkAdvancedSettingsPage(),
            ),
          ),
        ),
        ActionModel(
          id: 'appLogs',
          title: l10n.appLogs_title,
          subtitle: l10n.networkSettings_appLogsDesc,
          wrapSubtitle: true,
          icon: Symbols.article_rounded,
          onTap: (context, _) => _openLogs(context, LogTypeFilter.all),
        ),
        ActionModel(
          id: 'networkLogs',
          title: l10n.debugTools_networkLogs,
          subtitle: l10n.debugTools_networkLogsDesc,
          wrapSubtitle: true,
          icon: Symbols.dns_rounded,
          onTap: (context, _) => _openLogs(context, LogTypeFilter.network),
        ),
        // CF 验证日志只在开发者模式下落盘，入口也只在开发者模式下给
        ActionModel(
          id: 'cfLogs',
          title: l10n.debugTools_cfLogs,
          subtitle: l10n.debugTools_cfLogsDesc,
          wrapSubtitle: true,
          icon: Symbols.shield_rounded,
          visibleWhen: (ref) =>
              ref.read(sharedPreferencesProvider).getBool('developer_mode') ??
              false,
          onTap: (context, _) => _openLogs(context, LogTypeFilter.cfChallenge),
        ),
      ],
    ),
  ];
}

/// 网络设置（高级页面）
List<SettingsGroup> buildNetworkAdvancedGroups(BuildContext context) {
  final l10n = context.l10n;
  return [
    // 节点优选：优选方式 + 帮助优选 + 隐私说明
    SettingsGroup(
      title: l10n.cfSelect_title,
      icon: Symbols.alt_route_rounded,
      wrapInCard: false,
      items: [
        CustomModel(
          id: 'cfSelect',
          title: l10n.cfSelect_title,
          subtitle: l10n.cfSelect_searchDesc,
          builder: (_, _) => const CfSelectCard(),
        ),
      ],
    ),

    // 网关：连接加速总开关、证书、网关状态、DNS 与网关细节
    SettingsGroup(
      title: l10n.networkSettings_gateway,
      icon: Symbols.hub_rounded,
      wrapInCard: false,
      items: [
        CustomModel(
          id: 'dohSettings',
          title: l10n.accel_title,
          subtitle: l10n.accel_searchDesc,
          builder: (_, _) => const DohSettingsCard(),
        ),
      ],
    ),

    // 引擎组合：在三种预设之外逐项开关
    SettingsGroup(
      title: l10n.engineMix_title,
      icon: Symbols.speed_rounded,
      wrapInCard: false,
      items: [
        CustomModel(
          id: 'engineMix',
          title: l10n.engineMix_title,
          subtitle: l10n.engineMix_searchDesc,
          builder: (_, _) => const EngineMixCard(),
        ),
      ],
    ),

    // 请求与上传
    SettingsGroup(
      title: l10n.networkSettings_requestsUploads,
      icon: Symbols.cloud_upload_rounded,
      wrapInCard: false,
      items: [
        CustomModel(
          id: 'rateLimit',
          title: l10n.networkSettings_rateLimitTitle,
          subtitle: l10n.networkSettings_rateLimitSubtitle,
          builder: (_, _) => const RateLimitCard(),
        ),
        CustomModel(
          id: 'forceDisableMultipartUpload',
          title: l10n.networkSettings_forceDisableMultipart,
          subtitle: l10n.networkSettings_forceDisableMultipartDescription,
          builder: (context, ref) {
            final value = ref
                .watch(preferencesProvider)
                .forceDisableMultipartUpload;
            final theme = Theme.of(context);
            return SegmentedCardGroup(
              children: [
                SwitchListTile(
                  secondary: Icon(
                    Symbols.cloud_upload_rounded,
                    color: value
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                  title: Text(l10n.networkSettings_forceDisableMultipart),
                  subtitle: Text(
                    l10n.networkSettings_forceDisableMultipartDescription,
                  ),
                  value: value,
                  onChanged: (v) => ref
                      .read(preferencesProvider.notifier)
                      .setForceDisableMultipartUpload(v),
                ),
              ],
            );
          },
        ),
      ],
    ),

    // 调试
    SettingsGroup(
      title: l10n.networkSettings_debug,
      icon: Symbols.bug_report_rounded,
      wrapInCard: false,
      items: [
        CustomModel(
          id: 'erudaConsole',
          title: l10n.eruda_title,
          subtitle: l10n.eruda_offDesc,
          builder: (_, _) => const ErudaCard(),
        ),
      ],
    ),
  ];
}

void _openLogs(BuildContext context, LogTypeFilter type) {
  Navigator.of(context)
      .push(MaterialPageRoute(builder: (_) => AppLogsPage(initialType: type)));
}

Future<void> _manualVerify(BuildContext context) async {
  final result = await CfChallengeService().showManualVerifyNow(context, true);
  if (result == true) {
    ToastService.showSuccess(S.current.common_success);
  } else if (result == false) {
    ToastService.showError(S.current.cf_failedRetry);
  } else {
    ToastService.showError(S.current.cf_cannotOpenVerifyPage);
  }
}
