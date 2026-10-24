
import 'package:common_ui/common_ui.dart' show MenuQuickActionStyle;
import 'package:flutter/material.dart';
import 'package:fluxdo_render/fluxdo_render.dart' show FluxdoRenderStyle;
import 'package:m3e_ui/m3e_ui.dart' show SegmentedCardStyle;

import 'theme_resolver.dart';

/// Anthropic Claude 风格的人文温润设计令牌。
///
/// 包含亮色（Warm Parchment 羊皮纸暖白）与暗色（Warm Charcoal 暖炭黑）两套变体。
/// 支持深色 OLED 纯黑纸底（[black] = true）。
/// 强调色为 Claude 标志性的陶土红（Terracotta / Coral）。
/// 字体完全沿用全局设置，不在标题处硬编码任何特定字体族。
@immutable
class ClaudeTokens extends ThemeExtension<ClaudeTokens> {
  const ClaudeTokens({
    required this.background,
    required this.surface1,
    required this.surface2,
    required this.surface3,
    required this.textPrimary,
    required this.textSecondary,
    required this.textMuted,
    required this.border,
    required this.borderStrong,
    required this.accent,
    required this.accentSoft,
    required this.success,
    required this.warning,
    required this.error,
  });

  /// 主背景色（画布/Scaffold 底色）
  final Color background;

  /// 卡片与容器主表面
  final Color surface1;

  /// 悬停态与次级容器表面
  final Color surface2;

  /// 激活/选中态与最高层容器表面
  final Color surface3;

  /// 主要文本（深暖黑 / 暖白）
  final Color textPrimary;

  /// 次要文本与说明文字
  final Color textSecondary;

  /// 弱化提示、占位符与禁用文字
  final Color textMuted;

  /// 默认边框与细分割线
  final Color border;

  /// 强调边框与聚焦分割线
  final Color borderStrong;

  /// Claude 标志性陶土红强调色
  final Color accent;

  /// 强调色极淡底（胶囊、选区、徽标背景）
  final Color accentSoft;

  /// 成功色（温润草木绿）
  final Color success;

  /// 警告色（温润琥珀橙）
  final Color warning;

  /// 错误色（温润砖红）
  final Color error;

  /// [black]: 深色用纯黑底（OLED），只影响深色；强调色与文字色保持温润。
  static ClaudeTokens of(Brightness brightness, {bool black = false}) {
    final light = brightness == Brightness.light;
    final oled = !light && black;
    return light
        ? const ClaudeTokens(
            background: Color(0xFFFAF8F5),
            surface1: Color(0xFFF3EFEA),
            surface2: Color(0xFFEAE3D9),
            surface3: Color(0xFFDFD7CA),
            textPrimary: Color(0xFF262320),
            textSecondary: Color(0xFF5E564F),
            textMuted: Color(0xFF8C827A),
            border: Color(0xFFE5DDD0),
            borderStrong: Color(0xFFD4CCC0),
            accent: Color(0xFFDA7756),
            accentSoft: Color(0x26DA7756),
            success: Color(0xFF2E7D32),
            warning: Color(0xFFD97706),
            error: Color(0xFFC93B2B),
          )
        : ClaudeTokens(
            background:
                oled ? const Color(0xFF000000) : const Color(0xFF181614),
            surface1:
                oled ? const Color(0xFF12100E) : const Color(0xFF201D1B),
            surface2:
                oled ? const Color(0xFF1C1917) : const Color(0xFF2A2623),
            surface3:
                oled ? const Color(0xFF262320) : const Color(0xFF38332F),
            textPrimary: const Color(0xFFF0EDE6),
            textSecondary: const Color(0xFFB8B0A5),
            textMuted: const Color(0xFF7D756C),
            border: oled ? const Color(0xFF262320) : const Color(0xFF38332F),
            borderStrong:
                oled ? const Color(0xFF38332F) : const Color(0xFF4A443F),
            accent: const Color(0xFFE07A5F),
            accentSoft: const Color(0x26E07A5F),
            success: const Color(0xFF52B788),
            warning: const Color(0xFFE5A93C),
            error: const Color(0xFFE76F51),
          );
  }

  @override
  ClaudeTokens copyWith({
    Color? background,
    Color? surface1,
    Color? surface2,
    Color? surface3,
    Color? textPrimary,
    Color? textSecondary,
    Color? textMuted,
    Color? border,
    Color? borderStrong,
    Color? accent,
    Color? accentSoft,
    Color? success,
    Color? warning,
    Color? error,
  }) {
    return ClaudeTokens(
      background: background ?? this.background,
      surface1: surface1 ?? this.surface1,
      surface2: surface2 ?? this.surface2,
      surface3: surface3 ?? this.surface3,
      textPrimary: textPrimary ?? this.textPrimary,
      textSecondary: textSecondary ?? this.textSecondary,
      textMuted: textMuted ?? this.textMuted,
      border: border ?? this.border,
      borderStrong: borderStrong ?? this.borderStrong,
      accent: accent ?? this.accent,
      accentSoft: accentSoft ?? this.accentSoft,
      success: success ?? this.success,
      warning: warning ?? this.warning,
      error: error ?? this.error,
    );
  }

  @override
  ClaudeTokens lerp(covariant ClaudeTokens? other, double t) {
    if (other == null) return this;
    Color c(Color a, Color b) => Color.lerp(a, b, t)!;
    return ClaudeTokens(
      background: c(background, other.background),
      surface1: c(surface1, other.surface1),
      surface2: c(surface2, other.surface2),
      surface3: c(surface3, other.surface3),
      textPrimary: c(textPrimary, other.textPrimary),
      textSecondary: c(textSecondary, other.textSecondary),
      textMuted: c(textMuted, other.textMuted),
      border: c(border, other.border),
      borderStrong: c(borderStrong, other.borderStrong),
      accent: c(accent, other.accent),
      accentSoft: c(accentSoft, other.accentSoft),
      success: c(success, other.success),
      warning: c(warning, other.warning),
      error: c(error, other.error),
    );
  }
}

/// Claude 主题配色与组件样式装配。
class ClaudeTheme {
  ClaudeTheme._();

  /// Claude 的 ColorScheme。
  ///
  /// 所有角色显式指定，不走 fromSeed：
  /// - primary 为 Claude 标志性陶土红；
  /// - secondary 为暖调中性文字色；
  /// - tertiary 为温润草木绿；
  /// - surface 是温润羊皮纸（日间）或暖炭咖啡黑（夜间）；
  /// - [black] 为 true 时，深色表面换用 OLED 纯黑梯级；
  /// - surfaceTint 设为透明（不给卡片涂额外的种子色调）。
  static ColorScheme colorScheme(
    Brightness brightness, {
    bool black = false,
  }) {
    final t = ClaudeTokens.of(brightness, black: black);
    final light = brightness == Brightness.light;
    final oled = !light && black;
    final onAccent = light ? const Color(0xFFFFFFFF) : const Color(0xFF181614);
    Color tint(Color c, double a) =>
        Color.alphaBlend(c.withValues(alpha: a), t.background);

    return ColorScheme(
      brightness: brightness,
      primary: t.accent,
      onPrimary: onAccent,
      primaryContainer: tint(t.accent, light ? 0.14 : 0.22),
      onPrimaryContainer:
          light ? const Color(0xFF8B351B) : const Color(0xFFF5BAA8),
      secondary: t.textSecondary,
      onSecondary: onAccent,
      secondaryContainer: light
          ? t.surface2
          : oled
          ? const Color(0xFF1C1917)
          : t.surface2,
      onSecondaryContainer: t.textPrimary,
      tertiary: t.success,
      onTertiary: onAccent,
      tertiaryContainer: tint(t.success, light ? 0.14 : 0.22),
      onTertiaryContainer:
          light ? const Color(0xFF0E3B13) : const Color(0xFFB2E3CB),
      error: t.error,
      onError: light ? const Color(0xFFFFFFFF) : const Color(0xFF181614),
      errorContainer: tint(t.error, light ? 0.12 : 0.22),
      onErrorContainer:
          light ? const Color(0xFF5E120A) : const Color(0xFFF7C2B8),
      surface: t.background,
      onSurface: t.textPrimary,
      onSurfaceVariant: t.textSecondary,
      surfaceDim: light
          ? const Color(0xFFEFE9DF)
          : oled
          ? const Color(0xFF000000)
          : const Color(0xFF131110),
      surfaceBright: light
          ? const Color(0xFFFFFFFF)
          : oled
          ? const Color(0xFF221F1C)
          : const Color(0xFF26221F),
      surfaceContainerLowest: light
          ? const Color(0xFFFFFFFF)
          : oled
          ? const Color(0xFF000000)
          : const Color(0xFF141210),
      surfaceContainerLow: light
          ? const Color(0xFFF6F3EE)
          : oled
          ? const Color(0xFF0A0908)
          : const Color(0xFF1C1A18),
      surfaceContainer: t.surface1,
      surfaceContainerHigh: t.surface2,
      surfaceContainerHighest: t.surface3,
      outline: t.textMuted,
      outlineVariant: t.border,
      inverseSurface: light ? t.textPrimary : t.background,
      onInverseSurface: light ? t.background : t.textPrimary,
      inversePrimary:
          light ? const Color(0xFFE07A5F) : const Color(0xFFDA7756),
      surfaceTint: Colors.transparent,
      shadow: Colors.black,
      scrim: Colors.black,
    );
  }

  /// Claude 的明暗两套配色（不支持透明背景）。[black] = 深色用纯黑（OLED）。
  static ResolvedTheme resolve(ThemeMode mode, {bool black = false}) {
    return ResolvedTheme(
      light: colorScheme(Brightness.light),
      dark: colorScheme(Brightness.dark, black: black),
      mode: mode,
      transparent: false,
    );
  }

  /// 分类色块：服务端给的十六进制色；深色模式掺三成白，免得暗色分类在暗底上看不见。
  static Color categoryColor(String hex, Brightness brightness) {
    final clean = hex.replaceAll('#', '');
    final c = clean.length == 6
        ? Color(int.parse('FF$clean', radix: 16))
        : const Color(0xFF9E9E9E);
    return brightness == Brightness.dark
        ? Color.lerp(c, const Color(0xFFFFFFFF), 0.3)!
        : c;
  }

  /// 组装 Claude 的 ThemeData。
  ///
  /// [fontFamily] 完全沿用全局设置：标题、正文、说明一律采用用户选定的字体，
  /// 不强制覆盖任何特定字体族。
  static ThemeData build({
    required ColorScheme scheme,
    required String? fontFamily,
    required PageTransitionsTheme pageTransitionsTheme,
    required IconThemeData iconTheme,
    required IconThemeData primaryIconTheme,
    List<ThemeExtension<dynamic>> extensions = const [],
  }) {
    // 纯黑由配色带进来（深色且底色为纯黑），令牌跟着取同一套
    final black = scheme.brightness == Brightness.dark &&
        scheme.surface.toARGB32() == 0xFF000000;
    final t = ClaudeTokens.of(scheme.brightness, black: black);
    final roundedPill = WidgetStatePropertyAll<OutlinedBorder>(
      RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    );

    return ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      fontFamily: fontFamily,
      scaffoldBackgroundColor: t.background,
      canvasColor: t.background,
      dividerColor: t.border,
      pageTransitionsTheme: pageTransitionsTheme,
      iconTheme: iconTheme,
      primaryIconTheme: primaryIconTheme,
      extensions: [
        ...extensions,
        t,
        FluxdoRenderStyle(
          quoteBarColor: t.accent,
          quoteBarWidth: 3,
          quoteBackground: t.surface1,
          quoteRadius: 4,
          quoteTextColor: t.textSecondary,
          quoteFontFamily: null, // 字体沿用全局设置：不硬编码字体族
          headingFontFamily: null, // 字体沿用全局设置：不硬编码字体族
          headingColor: t.textPrimary,
          ruleColor: t.border,
        ),
        // 设置、我的、会话列表等分段卡片组：平铺细线列表
        SegmentedCardStyle(flat: true, dividerColor: t.border),
        // 菜单顶部快捷按钮：细线圆圈，选中描强调色、底色极淡
        MenuQuickActionStyle(
          fill: Colors.transparent,
          activeFill: t.accentSoft,
          iconColor: t.textSecondary,
          activeIconColor: t.accent,
          border: t.borderStrong,
          activeBorder: t.accent.withValues(alpha: 0.6),
        ),
      ],
      appBarTheme: AppBarThemeData(
        backgroundColor: t.background,
        foregroundColor: t.textPrimary,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        titleTextStyle: TextStyle(
          fontFamily: fontFamily,
          fontSize: 19,
          fontWeight: FontWeight.w600,
          color: t.textPrimary,
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: t.surface1,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: t.border),
        ),
      ),
      dividerTheme: DividerThemeData(
        color: t.border,
        thickness: 1,
        space: 1,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: ButtonStyle(
          backgroundColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.disabled)
                ? t.accent.withValues(alpha: 0.38)
                : t.accent,
          ),
          foregroundColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.disabled)
                ? scheme.onPrimary.withValues(alpha: 0.6)
                : scheme.onPrimary,
          ),
          elevation: const WidgetStatePropertyAll(0),
          shape: roundedPill,
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ButtonStyle(
          elevation: const WidgetStatePropertyAll(0),
          backgroundColor: WidgetStatePropertyAll(t.surface2),
          foregroundColor: WidgetStatePropertyAll(t.textPrimary),
          shape: roundedPill,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: ButtonStyle(
          foregroundColor: WidgetStatePropertyAll(t.textPrimary),
          side: WidgetStateProperty.resolveWith(
            (s) => BorderSide(
              color:
                  s.contains(WidgetState.disabled) ? t.border : t.borderStrong,
            ),
          ),
          shape: roundedPill,
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: t.accent,
        foregroundColor: scheme.onPrimary,
        elevation: 2,
        focusElevation: 3,
        hoverElevation: 4,
        highlightElevation: 2,
        shape: const StadiumBorder(),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: t.surface1,
        selectedColor: t.accentSoft,
        checkmarkColor: t.accent,
        side: WidgetStateBorderSide.resolveWith(
          (s) => BorderSide(
            color: s.contains(WidgetState.selected) ? t.accent : t.border,
          ),
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        // 颜色用 WidgetStateColor 解析，避免 RawChip merge 样式时丢失解析器
        labelStyle: TextStyle(
          color: WidgetStateColor.resolveWith(
            (s) => s.contains(WidgetState.disabled)
                ? t.textMuted
                : s.contains(WidgetState.selected)
                ? t.accent
                : t.textSecondary,
          ),
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected)
              ? scheme.onPrimary
              : t.textSecondary,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? t.accent : t.surface3,
        ),
        trackOutlineColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? t.accent : t.border,
        ),
      ),
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? t.accent : null,
        ),
        checkColor: WidgetStatePropertyAll(scheme.onPrimary),
        side: BorderSide(color: t.borderStrong, width: 1.5),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      ),
      radioTheme: RadioThemeData(
        fillColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? t.accent : t.textMuted,
        ),
      ),
      tabBarTheme: TabBarThemeData(
        indicator: UnderlineTabIndicator(
          borderSide: BorderSide(color: t.accent, width: 2.5),
          insets: const EdgeInsets.symmetric(horizontal: 16),
        ),
        indicatorSize: TabBarIndicatorSize.label,
        labelColor: t.textPrimary,
        unselectedLabelColor: t.textMuted,
        dividerColor: t.border,
        labelStyle: const TextStyle(fontWeight: FontWeight.w600),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: t.background,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        indicatorColor: t.accentSoft,
        iconTheme: WidgetStateProperty.resolveWith(
          (s) => IconThemeData(
            color: s.contains(WidgetState.selected) ? t.accent : t.textMuted,
          ),
        ),
        labelTextStyle: WidgetStateProperty.resolveWith(
          (s) => TextStyle(
            fontSize: 11,
            letterSpacing: 0.3,
            color: s.contains(WidgetState.selected) ? t.accent : t.textMuted,
            fontWeight: s.contains(WidgetState.selected)
                ? FontWeight.w600
                : FontWeight.w400,
          ),
        ),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: t.background,
        indicatorColor: t.accentSoft,
        selectedIconTheme: IconThemeData(color: t.accent),
        unselectedIconTheme: IconThemeData(color: t.textMuted),
        selectedLabelTextStyle: TextStyle(
          color: t.accent,
          fontWeight: FontWeight.w600,
        ),
        unselectedLabelTextStyle: TextStyle(color: t.textMuted),
      ),
      inputDecorationTheme: InputDecorationThemeData(
        filled: true,
        fillColor: t.surface1,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: t.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: t.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: t.accent, width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: t.error),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: t.error, width: 1.5),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: t.surface1,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        titleTextStyle: TextStyle(
          fontFamily: fontFamily,
          fontSize: 20,
          fontWeight: FontWeight.w600,
          color: t.textPrimary,
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: t.surface1,
        modalBackgroundColor: t.surface1,
        surfaceTintColor: Colors.transparent,
        dragHandleColor: t.borderStrong,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: t.border),
        ),
        elevation: 3,
        color: t.surface1,
        surfaceTintColor: Colors.transparent,
        menuPadding: const EdgeInsets.symmetric(vertical: 6),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: scheme.inverseSurface,
        actionTextColor: t.accent,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: scheme.inverseSurface,
          borderRadius: BorderRadius.circular(6),
        ),
        textStyle: TextStyle(color: scheme.onInverseSurface, fontSize: 12),
      ),
      badgeTheme: BadgeThemeData(
        backgroundColor: t.accent,
        textColor: scheme.onPrimary,
      ),
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: t.accent,
        selectionColor: t.accent.withValues(alpha: 0.25),
        selectionHandleColor: t.accent,
      ),
      scrollbarTheme: ScrollbarThemeData(
        thumbColor: WidgetStatePropertyAll(t.borderStrong),
      ),
      // ignore: deprecated_member_use
      sliderTheme: const SliderThemeData(year2023: true),
      // ignore: deprecated_member_use
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        // ignore: deprecated_member_use
        year2023: true,
        circularTrackPadding: EdgeInsets.zero,
      ),
    );
  }
}
