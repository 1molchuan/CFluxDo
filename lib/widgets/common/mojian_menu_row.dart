import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';

import '../../theme/mojian_theme.dart';

/// 墨笺的菜单行(设置首页、「我的」的功能列表):次要墨色线形图标 + 标题 +
/// 可选的右侧取值 + 箭头;不要彩色图标底块。分隔细线由外层分段卡片组
/// (墨笺下平铺)负责。
class MojianMenuRow extends StatelessWidget {
  const MojianMenuRow({
    super.key,
    required this.icon,
    required this.title,
    required this.onTap,
    this.value,
    this.trailing,
  });

  final IconData icon;
  final String title;
  final VoidCallback? onTap;

  /// 右侧的当前取值(小字次要墨色)
  final String? value;

  /// 替换默认箭头的行尾组件(角标、开关等)
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final mj = Theme.of(context).extension<MojianTokens>()!;
    return InkWell(
      onTap: onTap,
      child: SizedBox(
        height: 52,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Row(
            children: [
              Icon(icon, size: 20, color: mj.ink3),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 15, color: mj.ink),
                ),
              ),
              if (value != null && value!.isNotEmpty) ...[
                Text(value!, style: TextStyle(fontSize: 13, color: mj.ink3)),
                const SizedBox(width: 6),
              ],
              trailing ??
                  Icon(Symbols.chevron_right_rounded, size: 20, color: mj.ink4),
            ],
          ),
        ),
      ),
    );
  }
}
