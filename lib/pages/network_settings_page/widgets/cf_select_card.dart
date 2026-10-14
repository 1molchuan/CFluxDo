import 'dart:async';

import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:m3e_ui/m3e_ui.dart';

import '../../../l10n/s.dart';
import '../../../services/network/doh/cfhub_probe_auth_service.dart';
import '../../../services/network/doh/network_settings_service.dart';
import '../../../services/network/doh_proxy/doh_proxy_ffi.dart';
import '../../../services/network/proxy/proxy_settings_service.dart';
import '../../../services/toast_service.dart';
import '../../../utils/time_utils.dart';
import 'cf_select_privacy_dialog.dart';

/// 连接方式卡片（本地优选）
///
/// 1.1 起 App 自己在 Cloudflare 共享池里测速选节点，atlas 节点表一起参与竞速。
/// 卡片提供：模式切换（本地优选 + atlas / 只用 atlas 池）、当前优选状态、
/// 手动重新优选、隐私说明入口，以及「帮助优选」（向 cfhub 分享测量结果）开关。
///
/// 优选状态由 Rust 侧维护，这里每 3 秒拉一次快照刷新 [NetworkSettingsService.selectStatusNotifier]。
class CfSelectCard extends StatefulWidget {
  const CfSelectCard({super.key});

  @override
  State<CfSelectCard> createState() => _CfSelectCardState();
}

class _CfSelectCardState extends State<CfSelectCard> {
  static const _refreshInterval = Duration(seconds: 3);

  Timer? _refreshTimer;

  /// 正在走 cfhub 授权流程（期间禁用开关、显示进度）
  bool _enablingShare = false;

  /// 正在请求重新优选（防止连点）
  bool _reracing = false;

  /// 上次看到的 rejectedNotifier 值，变化才弹「授权已失效」
  late int _lastRejected;

  @override
  void initState() {
    super.initState();
    final rejected = CfhubProbeAuthService.instance.rejectedNotifier;
    _lastRejected = rejected.value;
    rejected.addListener(_onRejectedChanged);

    unawaited(_refreshStatus());
    _refreshTimer = Timer.periodic(_refreshInterval, (_) {
      unawaited(_refreshStatus());
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    CfhubProbeAuthService.instance.rejectedNotifier.removeListener(
      _onRejectedChanged,
    );
    super.dispose();
  }

  Future<void> _refreshStatus() async {
    try {
      await NetworkSettingsService.instance.refreshSelectStatus();
    } catch (e) {
      // 代理未起或 FFI 暂不可用时拉不到快照，下个周期再试即可
      debugPrint('[CfSelect] 刷新优选状态失败: $e');
    }
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
        final status = service.selectStatusNotifier.value;

        return Card(
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 标题 + 模式切换
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
                child: _buildModeSelector(theme, settings.selectMode),
              ),
              _divider(theme),
              // 当前状态
              _buildStatusRow(theme, service, settings, status),
              // 操作行
              _buildActionRow(theme, service),
              _divider(theme),
              // 帮助优选
              _buildShareTile(theme, settings),
            ],
          ),
        );
      },
    );
  }

  // ---- 模式 ----

  Widget _buildModeSelector(ThemeData theme, CfSelectMode mode) {
    final l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              Symbols.alt_route_rounded,
              size: 18,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(width: 8),
            Text(
              l10n.cfSelect_title,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        SizedBox(
          width: double.infinity,
          child: M3eButtonGroup<CfSelectMode>(
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
            onSelected: (value) =>
                unawaited(NetworkSettingsService.instance.setSelectMode(value)),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          switch (mode) {
            CfSelectMode.localAtlas => l10n.cfSelect_modeLocalAtlasDesc,
            CfSelectMode.atlasOnly => l10n.cfSelect_modeAtlasOnlyDesc,
          },
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  // ---- 状态行 ----

  Widget _buildStatusRow(
    ThemeData theme,
    NetworkSettingsService service,
    NetworkSettings settings,
    DohSelectStatus? status,
  ) {
    final l10n = context.l10n;
    final cs = theme.colorScheme;
    final eligible = service.selectorEligible;

    Widget leading;
    String text;
    Color color = cs.onSurfaceVariant;

    if (!eligible) {
      // 应用代理开启 / 加速关闭时 Rust 侧不做优选，给出原因
      leading = Icon(Symbols.block_rounded, size: 18, color: cs.onSurfaceVariant);
      text = ProxySettingsService.instance.current.isValid
          ? l10n.cfSelect_disabledByProxy
          : l10n.cfSelect_disabledByDoh;
    } else {
      switch (status?.phase ?? 'idle') {
        case 'verifying':
          leading = _progress(cs.primary);
          text = l10n.cfSelect_statusVerifying;
        case 'racing':
          leading = _progress(cs.primary);
          text = l10n.cfSelect_statusRacing;
        case 'ready':
          leading = const Icon(
            Symbols.check_circle_rounded,
            size: 18,
            color: Colors.green,
          );
          text = l10n.cfSelect_statusReady(
            status?.winnerIp ?? '-',
            status?.latencyMs ?? 0,
          );
          color = cs.onSurface;
        case 'failed':
          leading = Icon(Symbols.error_rounded, size: 18, color: cs.error);
          text = l10n.cfSelect_statusFailed;
          color = cs.error;
        default:
          leading = Icon(
            Symbols.hourglass_top_rounded,
            size: 18,
            color: cs.onSurfaceVariant,
          );
          text = l10n.cfSelect_statusIdle;
      }
    }

    // 补充信息：赢家来源、上次优选时间
    final extras = <String>[];
    if (eligible && status != null) {
      final source = status.source;
      if (status.phase == 'ready' && source != null && source.isNotEmpty) {
        extras.add(source);
      }
      if (status.lastRaceAt > 0) {
        final at = DateTime.fromMillisecondsSinceEpoch(status.lastRaceAt * 1000);
        extras.add(l10n.cfSelect_lastRace(TimeUtils.formatRelativeTime(at)));
      }
    }
    final lastError = eligible && status?.phase == 'failed'
        ? status?.lastError
        : null;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(padding: const EdgeInsets.only(top: 1), child: leading),
              const SizedBox(width: 8),
              Expanded(
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: text,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: color,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (extras.isNotEmpty)
                        TextSpan(
                          text: '  ·  ${extras.join('  ·  ')}',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                    ],
                  ),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          if (lastError != null && lastError.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 26, top: 4),
              child: Text(
                lastError,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: cs.onSurfaceVariant,
                  fontSize: 11,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
      ),
    );
  }

  Widget _progress(Color color) => SizedBox(
    width: 16,
    height: 16,
    child: Padding(
      padding: const EdgeInsets.all(1),
      child: CircularProgressIndicator(strokeWidth: 2, color: color),
    ),
  );

  // ---- 操作行 ----

  Widget _buildActionRow(ThemeData theme, NetworkSettingsService service) {
    final l10n = context.l10n;
    final canRerace = service.selectorEligible && !_reracing;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
      child: Row(
        children: [
          OutlinedButton.icon(
            onPressed: canRerace ? _rerace : null,
            icon: const Icon(Symbols.refresh_rounded, size: 18),
            label: Text(l10n.cfSelect_rerace),
          ),
          const SizedBox(width: 8),
          TextButton(
            onPressed: () =>
                showCfSelectPrivacyDialog(context, firstLaunch: false),
            child: Text(l10n.cfSelect_viewPrivacy),
          ),
        ],
      ),
    );
  }

  Future<void> _rerace() async {
    setState(() => _reracing = true);
    try {
      final started = await NetworkSettingsService.instance.reraceSelection();
      if (started) {
        ToastService.showInfo(S.current.cfSelect_reraceStarted);
        unawaited(_refreshStatus());
      } else {
        ToastService.showInfo(S.current.cfSelect_reraceCooldown);
      }
    } catch (e) {
      ToastService.showError(S.current.common_operationFailed('$e'));
    } finally {
      if (mounted) setState(() => _reracing = false);
    }
  }

  // ---- 帮助优选 ----

  Widget _buildShareTile(ThemeData theme, NetworkSettings settings) {
    final l10n = context.l10n;
    final on = settings.shareMeasurements;
    final authorized = on && CfhubProbeAuthService.instance.isAuthorized;

    return SwitchListTile(
      dense: true,
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

  // ---- 小组件 ----

  Widget _divider(ThemeData theme) => Divider(
    height: 1,
    color: theme.colorScheme.outlineVariant.withValues(alpha: 0.2),
  );
}
