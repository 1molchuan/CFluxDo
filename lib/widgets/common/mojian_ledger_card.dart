import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:m3e_ui/m3e_ui.dart';

import '../../theme/mojian_theme.dart';

/// 墨笺的「账本卡」:纸笺底、发丝线框、小圆角,无渐变无阴影。
/// 头行 = 线形图标 + 宋体小报名(字距拉开)+ 行尾附件(转圈 / 关闭按钮),
/// 下面是调用方给的正文(大号宋体数字、状态文字、按钮等)。
/// 元宇宙页的 LDC / CDK 余额卡在墨笺下都用它代替彩色渐变大卡。
class MojianLedgerCard extends StatelessWidget {
  const MojianLedgerCard({
    super.key,
    required this.icon,
    required this.title,
    required this.children,
    this.trailing,
    this.onTap,
    this.danger = false,
  });

  final IconData icon;
  final String title;
  final List<Widget> children;
  final Widget? trailing;
  final VoidCallback? onTap;

  /// 授权过期等异常:框线换成错误色
  final bool danger;

  /// 大号数字(余额、积分)
  static TextStyle figureStyle(MojianTokens mj) => TextStyle(
    fontFamily: mj.titleFamily,
    fontSize: 34,
    fontWeight: FontWeight.w700,
    height: 1.1,
    color: mj.ink,
  );

  /// 行尾的「关闭服务」按钮
  static Widget powerButton(MojianTokens mj, VoidCallback onTap) => IconButton(
    onPressed: onTap,
    icon: Icon(Symbols.power_settings_new_rounded, size: 18, color: mj.ink3),
    visualDensity: VisualDensity.compact,
  );

  /// 行尾的刷新转圈
  static Widget spinner(MojianTokens mj) =>
      LoadingSpinner(size: 18, color: mj.ink3);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mj = theme.extension<MojianTokens>()!;
    return Material(
      color: mj.paper3,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(6),
        side: BorderSide(
          color: danger
              ? theme.colorScheme.error.withValues(alpha: 0.5)
              : mj.rule,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 12, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                height: 36,
                child: Row(
                  children: [
                    Icon(
                      icon,
                      size: 18,
                      color: danger ? theme.colorScheme.error : mj.ink2,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: MojianTokens.titleFamilyFor(context),
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 2,
                          color: mj.ink2,
                        ),
                      ),
                    ),
                    ?trailing,
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: children,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
