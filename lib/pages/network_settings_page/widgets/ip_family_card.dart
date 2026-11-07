import 'dart:async';

import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:m3e_ui/m3e_ui.dart';

import '../../../l10n/s.dart';
import '../../../services/network/doh/network_settings_service.dart';

/// IP 协议卡片：自动 / IPv6 优先 / IPv4 优先（挑节点时偏好的地址族）
class IpFamilyCard extends StatelessWidget {
  const IpFamilyCard({super.key});

  @override
  Widget build(BuildContext context) {
    final service = NetworkSettingsService.instance;
    final theme = Theme.of(context);
    final l10n = context.l10n;

    return ValueListenableBuilder<NetworkSettings>(
      valueListenable: service.notifier,
      builder: (context, settings, _) {
        final mode = settings.ipv6Mode;
        return SegmentedCardGroup(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  CardTitleRow(
                    icon: Symbols.language_rounded,
                    title: l10n.cfSelect_ipFamily,
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: M3eButtonGroup<Ipv6Mode>(
                      itemPadding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 10,
                      ),
                      items: [
                        M3eButtonGroupItem(
                          value: Ipv6Mode.auto,
                          label: Text(l10n.cfSelect_ipFamilyAuto),
                        ),
                        M3eButtonGroupItem(
                          value: Ipv6Mode.preferV6,
                          label: Text(l10n.cfSelect_ipFamilyV6),
                        ),
                        M3eButtonGroupItem(
                          value: Ipv6Mode.preferV4,
                          label: Text(l10n.cfSelect_ipFamilyV4),
                        ),
                      ],
                      selected: mode,
                      onSelected: (value) =>
                          unawaited(service.setIpv6Mode(value)),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    switch (mode) {
                      Ipv6Mode.auto => l10n.cfSelect_ipFamilyAutoDesc,
                      Ipv6Mode.preferV6 => l10n.cfSelect_ipFamilyV6Desc,
                      Ipv6Mode.preferV4 => l10n.cfSelect_ipFamilyV4Desc,
                    },
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

/// 卡片内的小标题行（图标 + 标题），网络设置各卡片共用
class CardTitleRow extends StatelessWidget {
  const CardTitleRow({super.key, required this.icon, required this.title});

  final IconData icon;
  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Icon(icon, size: 18, color: theme.colorScheme.primary),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            title,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }
}
