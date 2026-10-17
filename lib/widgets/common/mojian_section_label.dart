import 'package:flutter/material.dart';

import '../../theme/mojian_theme.dart';

/// 墨笺的分组小标题:宋体、小字号、字距拉开、次要墨色,不带图标。
/// 各页面原来的「图标 + titleSmall」分组标题在墨笺下统一换成它。
class MojianSectionLabel extends StatelessWidget {
  const MojianSectionLabel(this.text, {super.key, this.trailing});

  final String text;

  /// 行尾附件(计数、「清空」之类)
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final mj = Theme.of(context).extension<MojianTokens>()!;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Flexible(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontFamily: MojianTokens.serifFamily,
              fontWeight: FontWeight.w600,
              fontSize: 12.5,
              letterSpacing: 2.4,
              color: mj.ink3,
            ),
          ),
        ),
        if (trailing != null) ...[const Spacer(), trailing!],
      ],
    );
  }
}
