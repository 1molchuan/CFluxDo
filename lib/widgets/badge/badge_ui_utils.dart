import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import '../../models/badge.dart';
import '../../theme/mojian_theme.dart';
import '../../../../../l10n/s.dart';

class BadgeUIUtils {
  static bool _isDark(BuildContext context) {
    return Theme.of(context).brightness == Brightness.dark;
  }

  // ---------------------------------------------------------------------------
  // Colors - Refined for "Premium" feel
  // ---------------------------------------------------------------------------

  static Color getBadgeColor(BuildContext context, BadgeType type) {
    final isDark = _isDark(context);
    final mj = Theme.of(context).extension<MojianTokens>();
    if (mj != null) {
      // 墨笺:金 = 令牌里的金色,银 = 淡墨,铜 = 赭色(深浅色各一档,对比度够)
      switch (type) {
        case BadgeType.gold:
          return mj.gold;
        case BadgeType.silver:
          return mj.ink3;
        case BadgeType.bronze:
          return isDark ? const Color(0xFFC9987A) : const Color(0xFF8C5A3C);
      }
    }
    switch (type) {
      case BadgeType.gold:
        return isDark
            ? const Color(0xFFFFD700) // Gold (Bright)
            : const Color(0xFFF59E0B); // Amber 600
      case BadgeType.silver:
        return isDark
            ? const Color(0xFFE0E0E0) // Grey 300
            : const Color(0xFF78909C); // Blue Grey 400
      case BadgeType.bronze:
        return isDark
            ? const Color(0xFFFFAB91) // Deep Orange 200
            : const Color(0xFFA1887F); // Brown 300
    }
  }

  static Color getSectionColor(BuildContext context, BadgeType type) {
    return getBadgeColor(context, type);
  }

  // ---------------------------------------------------------------------------
  // Gradients - Softer, diagonal, luxurious
  // ---------------------------------------------------------------------------

  static LinearGradient getBadgeGradient(BuildContext context, BadgeType type) {
    final baseColor = getBadgeColor(context, type);
    final isDark = _isDark(context);
    if (Theme.of(context).extension<MojianTokens>() != null) return _flat;

    // Using a 3-stop gradient for depth
    return LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [
        baseColor.withValues(alpha:isDark ? 0.25 : 0.15),
        baseColor.withValues(alpha:isDark ? 0.10 : 0.05),
        baseColor.withValues(alpha:isDark ? 0.02 : 0.01),
      ],
      stops: const [0.0, 0.6, 1.0],
    );
  }

  /// 墨笺不用渐变:两端都透明
  static const _flat = LinearGradient(
    colors: [Colors.transparent, Colors.transparent],
  );

  static LinearGradient getHeaderGradient(BuildContext context, BadgeType type) {
    final baseColor = getBadgeColor(context, type);
    final isDark = _isDark(context);
    if (Theme.of(context).extension<MojianTokens>() != null) return _flat;

    return LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [
        baseColor.withValues(alpha:isDark ? 0.3 : 0.2),
        baseColor.withValues(alpha:isDark ? 0.05 : 0.02),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Card Decoration - Unified "Soft UI" Style
  // ---------------------------------------------------------------------------

  static BoxDecoration getCardDecoration(BuildContext context, BadgeType type) {
    final theme = Theme.of(context);
    final mj = theme.extension<MojianTokens>();
    if (mj != null) {
      // 墨笺:直角纸笺,顶边一道等级色细线,其余三边发丝线,无阴影
      final rule = BorderSide(color: mj.rule);
      return BoxDecoration(
        color: mj.paper3,
        border: Border(
          top: BorderSide(color: getBadgeColor(context, type), width: 2),
          left: rule,
          right: rule,
          bottom: rule,
        ),
      );
    }
    final isDark = _isDark(context);
    final gradient = getBadgeGradient(context, type);
    final borderColor = getBadgeColor(context, type);

    return BoxDecoration(
      color: theme.cardColor,
      gradient: gradient,
      borderRadius: BorderRadius.circular(20), // Moderner, larger radius
      border: Border.all(
        color: borderColor.withValues(alpha:isDark ? 0.3 : 0.2),
        width: 1.5,
      ),
      boxShadow: [
        BoxShadow(
          color: borderColor.withValues(alpha:isDark ? 0.1 : 0.08),
          blurRadius: 16,
          offset: const Offset(0, 8), // Soft spread shadow
          spreadRadius: -4,
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Icons & Text
  // ---------------------------------------------------------------------------

  static FaIconData getBadgeIcon(BadgeType type) {
    // Can differentiate icons if needed, currently uniform
    switch (type) {
      case BadgeType.gold:
        return FontAwesomeIcons.medal;
      case BadgeType.silver:
        return FontAwesomeIcons.medal;
      case BadgeType.bronze:
        return FontAwesomeIcons.medal;
    }
  }

  static String getBadgeTypeName(BadgeType type) {
    switch (type) {
      case BadgeType.gold:
        return S.current.badge_goldBadge;
      case BadgeType.silver:
        return S.current.badge_silverBadge;
      case BadgeType.bronze:
        return S.current.badge_bronzeBadge;
    }
  }
}
