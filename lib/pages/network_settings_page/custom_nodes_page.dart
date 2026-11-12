import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:m3e_ui/m3e_ui.dart';

import '../../l10n/s.dart';
import '../../services/network/doh/custom_node_input.dart';
import '../../services/network/doh/network_settings_service.dart';
import '../../services/network/doh_proxy/doh_proxy_ffi.dart';
import '../../services/network/proxy/proxy_settings_service.dart';
import '../../services/toast_service.dart';
import '../../utils/dialog_utils.dart';

/// 「节点优选」卡片里自定义节点入口的一句话摘要
String customNodesSummary(
  AppLocalizations l10n,
  List<String> nodes,
  DohSelectStatus? status,
) {
  if (nodes.isEmpty) return l10n.customNodes_entryDesc;
  final count = nodes.length;
  if (status != null && status.winnerIsCustom && status.winnerIp != null) {
    return l10n.customNodes_entryInUse(count);
  }
  final reported = status?.customNodes ?? const <DohCustomNodeStatus>[];
  final allTested =
      reported.isNotEmpty && reported.every((node) => node.state != 'pending');
  if (allTested && !reported.any((node) => node.isOk)) {
    return l10n.customNodes_entryNoneUsable(count);
  }
  return l10n.customNodes_entryCount(count);
}

/// 清单里一条节点的状态说明。[status] 为 null 表示引擎还没报这一条
/// （刚改完清单、网关正在重启）；[busy] 为引擎正在竞速 / 校验
String customNodeStateText(
  AppLocalizations l10n, {
  required String entry,
  required DohCustomNodeStatus? status,
  required bool busy,
}) {
  final waiting = busy
      ? l10n.customNodes_stateTesting
      : l10n.customNodes_statePending;
  if (status == null) return waiting;
  switch (status.state) {
    case 'ok':
      final ip = status.ip;
      final latency = status.latencyMs;
      return [
        status.active ? l10n.customNodes_stateInUse : l10n.customNodes_stateOk,
        if (latency != null && latency > 0) '$latency ms',
        // 域名：说明实际连到哪个地址
        if (ip != null && ip != entry) l10n.customNodes_resolvedTo(ip),
      ].join(' · ');
    case 'failed':
      return l10n.customNodes_stateFailed(_reasonText(l10n, status.detail));
    case 'not_cloudflare':
      return l10n.customNodes_stateNotCloudflare;
    case 'no_family':
      return l10n.customNodes_stateNoFamily(
        entry.contains(':') ? 'IPv6' : 'IPv4',
      );
    case 'demoted':
      return l10n.customNodes_stateDemoted;
    case 'unresolved':
      return l10n.customNodes_stateUnresolved;
    case 'invalid':
      return l10n.customNodes_stateInvalid;
    default:
      return waiting;
  }
}

/// 把引擎给的失败类型（如 `tcp_timeout`、`http_403`）归成几种说法
String _reasonText(AppLocalizations l10n, String? detail) {
  final kind = detail ?? '';
  if (kind.contains('timeout')) return l10n.customNodes_reasonTimeout;
  if (kind.startsWith('tcp')) return l10n.customNodes_reasonConnect;
  if (kind.startsWith('tls') || kind.startsWith('ech')) {
    return l10n.customNodes_reasonHandshake;
  }
  return l10n.customNodes_reasonResponse;
}

/// 自定义节点：用户自己填 Cloudflare IP / 优选域名，引擎优先用它们连接
///
/// 清单存在 [NetworkSettingsService]（改了就按新清单重启网关）；每一条通不通、
/// 现在用的是哪条，从引擎的优选状态里读（[DohSelectStatus.customNodes]），
/// 这里每 2 秒拉一次快照。
class CustomNodesPage extends StatefulWidget {
  const CustomNodesPage({super.key});

  @override
  State<CustomNodesPage> createState() => _CustomNodesPageState();
}

class _CustomNodesPageState extends State<CustomNodesPage> {
  static const _refreshInterval = Duration(seconds: 2);

  final NetworkSettingsService _service = NetworkSettingsService.instance;
  Timer? _refreshTimer;

  /// 正在请求重新测试（防止连点）
  bool _retesting = false;

  @override
  void initState() {
    super.initState();
    unawaited(_refreshStatus());
    _refreshTimer = Timer.periodic(_refreshInterval, (_) {
      unawaited(_refreshStatus());
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _refreshStatus() async {
    try {
      await _service.refreshSelectStatus();
    } catch (e) {
      // 网关正在重启时拉不到快照，下个周期再试
      debugPrint('[CustomNodes] 刷新优选状态失败: $e');
    }
  }

  /// 不做节点优选的原因（上游代理 / 加速关闭 / 网关关闭 / 平台不支持）；在做则为 null
  String? _ineligibleReason(AppLocalizations l10n) {
    if (_service.selectorEligible) return null;
    if (ProxySettingsService.instance.current.isValid) {
      return l10n.cfSelect_disabledByProxy;
    }
    if (!_service.current.dohEnabled) return l10n.cfSelect_disabledByDoh;
    return (Platform.isAndroid || Platform.isLinux || Platform.isWindows)
        ? l10n.netStatus_noSelectGateway
        : l10n.netStatus_noSelectPlatform;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final l10n = context.l10n;

    return AnimatedBuilder(
      animation: Listenable.merge([
        _service.notifier,
        _service.isApplying,
        _service.selectStatusNotifier,
        ProxySettingsService.instance.notifier,
      ]),
      builder: (context, _) {
        final nodes = _service.current.customNodes;
        final status = _service.selectStatusNotifier.value;
        final ineligible = _ineligibleReason(l10n);
        // 网关正在重启、或引擎正在竞速 / 校验（含不改阶段的后台竞速）
        final busy =
            ineligible == null &&
            (_service.isApplying.value ||
                _service.pendingStart ||
                (status != null &&
                    (status.busy ||
                        status.phase == 'racing' ||
                        status.phase == 'verifying')));
        final canAdd = nodes.length < CustomNodeInput.maxEntries;
        final hintStyle = theme.textTheme.bodySmall?.copyWith(
          color: cs.onSurfaceVariant,
        );

        return Scaffold(
          appBar: AppBar(title: Text(l10n.customNodes_title)),
          body: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Text(
                  l10n.customNodes_intro(CustomNodeInput.maxEntries),
                  style: hintStyle,
                ),
              ),
              if (ineligible != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 10, 4, 0),
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
              const SizedBox(height: 12),
              SegmentedCardGroup(
                children: [
                  if (nodes.isEmpty)
                    // 撑满整行：分组的分隔线按子项宽度画
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.fromLTRB(16, 18, 16, 18),
                      child: Text(l10n.customNodes_listEmpty, style: hintStyle),
                    ),
                  for (final node in nodes)
                    _buildNodeTile(
                      theme,
                      node,
                      // 不做优选时引擎不报状态，也不会去测
                      ineligible != null ? null : _statusOf(status, node),
                      busy: busy,
                      idle: ineligible != null,
                    ),
                  ListTile(
                    key: const ValueKey('custom-nodes-add'),
                    enabled: canAdd,
                    leading: const Icon(Symbols.add_rounded),
                    title: Text(l10n.customNodes_add),
                    onTap: canAdd ? _showAddDialog : null,
                  ),
                ],
              ),
              if (nodes.isNotEmpty && ineligible == null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: OutlinedButton.icon(
                      key: const ValueKey('custom-nodes-retest'),
                      style: const ButtonStyle(
                        visualDensity: VisualDensity.compact,
                      ),
                      onPressed: _retesting ? null : _retest,
                      icon: const Icon(Symbols.refresh_rounded, size: 18),
                      label: Text(l10n.customNodes_retest),
                    ),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 16, 4, 24),
                child: Text(l10n.customNodes_footer, style: hintStyle),
              ),
            ],
          ),
        );
      },
    );
  }

  DohCustomNodeStatus? _statusOf(DohSelectStatus? status, String node) {
    if (status == null) return null;
    for (final item in status.customNodes) {
      if (item.entry == node) return item;
    }
    return null;
  }

  Widget _buildNodeTile(
    ThemeData theme,
    String node,
    DohCustomNodeStatus? status, {
    required bool busy,
    required bool idle,
  }) {
    final cs = theme.colorScheme;
    final l10n = context.l10n;
    final state = status?.state ?? 'pending';
    final testing = !idle && busy && state == 'pending';
    final (IconData icon, Color color) = switch (state) {
      'ok' when status!.active => (Symbols.check_circle_rounded, Colors.green),
      'ok' => (Symbols.check_circle_rounded, cs.onSurfaceVariant),
      'failed' || 'unresolved' => (Symbols.cancel_rounded, cs.error),
      'not_cloudflare' || 'invalid' => (Symbols.block_rounded, cs.error),
      'no_family' ||
      'demoted' => (Symbols.pause_circle_rounded, cs.onSurfaceVariant),
      _ => (Symbols.schedule_rounded, cs.onSurfaceVariant),
    };
    return ListTile(
      key: ValueKey('custom-node-$node'),
      leading: testing
          ? SizedBox(
              width: 24,
              height: 24,
              child: Padding(
                padding: const EdgeInsets.all(3),
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: cs.primary,
                ),
              ),
            )
          : Icon(icon, color: color, fill: state == 'ok' ? 1 : 0),
      title: Text(node),
      subtitle: idle
          ? null
          : Text(
              customNodeStateText(
                l10n,
                entry: node,
                status: status,
                busy: busy,
              ),
            ),
      trailing: IconButton(
        icon: const Icon(Symbols.delete_rounded, size: 20),
        tooltip: l10n.customNodes_remove,
        onPressed: () => _remove(node),
      ),
    );
  }

  Future<void> _remove(String node) async {
    final next = [
      for (final item in _service.current.customNodes)
        if (item != node) item,
    ];
    await _service.setCustomNodes(next);
  }

  Future<void> _retest() async {
    setState(() => _retesting = true);
    try {
      final started = await _service.reraceSelection();
      ToastService.showInfo(
        started
            ? S.current.cfSelect_reraceStarted
            : S.current.cfSelect_reraceCooldown,
      );
      if (started) unawaited(_refreshStatus());
    } catch (e) {
      ToastService.showError(S.current.common_operationFailed('$e'));
    } finally {
      if (mounted) setState(() => _retesting = false);
    }
  }

  Future<void> _showAddDialog() async {
    final existing = _service.current.customNodes;
    final added = await showAppDialog<List<String>>(
      context: context,
      builder: (_) => CustomNodesAddDialog(existing: existing),
    );
    if (added == null || added.isEmpty) return;
    await _service.setCustomNodes([...existing, ...added]);
  }
}

/// 添加节点的输入框：一次可以粘多条，写错的、超出上限的当场指出来
class CustomNodesAddDialog extends StatefulWidget {
  const CustomNodesAddDialog({super.key, required this.existing});

  final List<String> existing;

  @override
  State<CustomNodesAddDialog> createState() => _CustomNodesAddDialogState();
}

class _CustomNodesAddDialogState extends State<CustomNodesAddDialog> {
  final TextEditingController _controller = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final l10n = context.l10n;
    final parsed = CustomNodeInput.parse(_controller.text);
    if (parsed.invalid.isNotEmpty) {
      setState(
        () => _error = l10n.customNodes_invalid(parsed.invalid.join('、')),
      );
      return;
    }
    final fresh = [
      for (final node in parsed.nodes)
        if (!widget.existing.contains(node)) node,
    ];
    if (fresh.isEmpty) {
      // 什么都没填就当取消；填的都已经有了就说一声
      if (parsed.nodes.isEmpty) {
        Navigator.pop(context);
      } else {
        setState(() => _error = l10n.customNodes_alreadyListed);
      }
      return;
    }
    final left = CustomNodeInput.maxEntries - widget.existing.length;
    if (fresh.length > left) {
      setState(
        () =>
            _error = l10n.customNodes_tooMany(CustomNodeInput.maxEntries, left),
      );
      return;
    }
    Navigator.pop(context, fresh);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AlertDialog(
      title: Text(l10n.customNodes_add),
      content: TextField(
        key: const ValueKey('custom-nodes-input'),
        controller: _controller,
        autofocus: true,
        minLines: 3,
        maxLines: 6,
        keyboardType: TextInputType.multiline,
        autocorrect: false,
        enableSuggestions: false,
        decoration: InputDecoration(
          labelText: l10n.customNodes_addLabel,
          alignLabelWithHint: true,
          helperText: l10n.customNodes_addHelper,
          helperMaxLines: 2,
          errorText: _error,
          errorMaxLines: 3,
        ),
        onChanged: (_) {
          if (_error != null) setState(() => _error = null);
        },
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.common_cancel),
        ),
        FilledButton(onPressed: _submit, child: Text(l10n.common_confirm)),
      ],
    );
  }
}
