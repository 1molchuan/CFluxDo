import 'package:flutter/material.dart';

import '../../theme/mojian_theme.dart';

/// 墨笺侧栏顶部的品牌:强调色方印「c」+ 宋体字标 cfluxdo(收起的窄侧栏只留方印)。
class MojianBrand extends StatelessWidget {
  const MojianBrand({super.key, required this.extended});

  final bool extended;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mj = theme.extension<MojianTokens>()!;
    final seal = Container(
      width: 26,
      height: 26,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: mj.accent,
        borderRadius: BorderRadius.circular(5),
        border: Border.all(
          color: theme.colorScheme.onPrimary.withValues(alpha: 0.22),
          width: 1.5,
        ),
      ),
      child: Text(
        'c',
        style: TextStyle(
          fontFamily: MojianTokens.serifFamily,
          fontWeight: FontWeight.w700,
          fontSize: 17,
          height: 1,
          color: theme.colorScheme.onPrimary,
        ),
      ),
    );
    return Padding(
      padding: EdgeInsets.fromLTRB(extended ? 22 : 0, 18, 0, 4),
      child: Row(
        mainAxisAlignment: extended
            ? MainAxisAlignment.start
            : MainAxisAlignment.center,
        children: [
          seal,
          if (extended) ...[
            const SizedBox(width: 9),
            Text(
              'cfluxdo',
              style: TextStyle(
                fontFamily: MojianTokens.serifFamily,
                fontWeight: FontWeight.w600,
                fontSize: 21,
                height: 1,
                letterSpacing: 0.3,
                color: mj.ink,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
