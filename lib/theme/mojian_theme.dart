import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:fluxdo_render/fluxdo_render.dart' show FluxdoRenderStyle;
import 'package:common_ui/common_ui.dart' show MenuQuickActionStyle;
import 'package:m3e_ui/m3e_ui.dart' show SegmentedCardStyle;

import 'claude_theme.dart';
import 'theme_resolver.dart';

/// 界面风格：墨笺（默认）/ Claude（人文温润陶土）/ 经典（Material 外观）
enum UiStyle { mojian, claude, classic }

/// 墨笺的强调色。只落在链接、选中、未读、进度这类少量位置；
/// 按钮、开关、悬浮按钮一律用墨色，避免满屏强调色。
enum MojianAccent {
  /// 朱砂
  cinnabar(Color(0xFFB23A26), Color(0xFFE3735A)),

  /// 黛青
  indigo(Color(0xFF2C5A78), Color(0xFF84B2D3)),

  /// 松烟
  pine(Color(0xFF3B6A4E), Color(0xFF87BE9C)),

  /// 赭石
  ochre(Color(0xFF875B22), Color(0xFFDCAA66));

  const MojianAccent(this.light, this.dark);

  final Color light;
  final Color dark;

  Color of(Brightness brightness) =>
      brightness == Brightness.light ? light : dark;
}

/// 墨笺的设计令牌：纸、墨、细线三组颜色，外加强调色与两种功能色。
///
/// 浅色是暖白纸，深色是深墨蓝。次要文字（[ink3]）在各层底色上对比度都 ≥ 4.5:1；
/// [ink4] 只用于装饰（分隔点、占位符），不承载需要读的信息。
@immutable
class MojianTokens extends ThemeExtension<MojianTokens> {
  const MojianTokens({
    required this.paper,
    required this.paper2,
    required this.paper3,
    required this.ink,
    required this.inkBody,
    required this.ink2,
    required this.ink3,
    required this.ink4,
    required this.rule,
    required this.ruleStrong,
    required this.accent,
    required this.jade,
    required this.gold,
  });

  /// 标题宋体（pubspec 里的字体族名）
  static const serifFamily = 'MojianSerif';

  final Color paper;
  final Color paper2;
  final Color paper3;
  final Color ink;
  final Color inkBody;
  final Color ink2;
  final Color ink3;
  final Color ink4;
  final Color rule;
  final Color ruleStrong;
  final Color accent;
  final Color jade;
  final Color gold;

  Color get accentSoft => accent.withValues(alpha: 0.09);

  /// [black]:深色用纯黑纸(OLED),只影响深色;墨色与强调色不变。
  static MojianTokens of(
    Brightness brightness,
    MojianAccent accent, {
    bool black = false,
    Color? accentColor,
  }) {
    final light = brightness == Brightness.light;
    final oled = !light && black;
    return MojianTokens(
      paper: light
          ? const Color(0xFFF6F2EA)
          : oled
          ? const Color(0xFF000000)
          : const Color(0xFF12161C),
      paper2: light
          ? const Color(0xFFEEE8DC)
          : oled
          ? const Color(0xFF101215)
          : const Color(0xFF0D1015),
      paper3: light
          ? const Color(0xFFFBF8F2)
          : oled
          ? const Color(0xFF0B0C0F)
          : const Color(0xFF181D25),
      ink: light ? const Color(0xFF1D1B18) : const Color(0xFFECE6DA),
      inkBody: light ? const Color(0xFF2E2A25) : const Color(0xFFD6CFC2),
      ink2: light ? const Color(0xFF4A453E) : const Color(0xFFBDB5A7),
      ink3: light ? const Color(0xFF68615A) : const Color(0xFF9A9385),
      ink4: light ? const Color(0xFFA9A195) : const Color(0xFF5F5A52),
      rule: light
          ? const Color(0xFFE3DBCD)
          : oled
          ? const Color(0xFF1E2228)
          : const Color(0xFF242A33),
      ruleStrong: light
          ? const Color(0xFFCDC3B1)
          : oled
          ? const Color(0xFF30363E)
          : const Color(0xFF343C47),
      accent: accentColor ?? accent.of(brightness),
      jade: light ? const Color(0xFF2F6450) : const Color(0xFF78B39C),
      gold: light ? const Color(0xFF977633) : const Color(0xFFCFAE6A),
    );
  }

  @override
  MojianTokens copyWith({
    Color? paper,
    Color? paper2,
    Color? paper3,
    Color? ink,
    Color? inkBody,
    Color? ink2,
    Color? ink3,
    Color? ink4,
    Color? rule,
    Color? ruleStrong,
    Color? accent,
    Color? jade,
    Color? gold,
  }) {
    return MojianTokens(
      paper: paper ?? this.paper,
      paper2: paper2 ?? this.paper2,
      paper3: paper3 ?? this.paper3,
      ink: ink ?? this.ink,
      inkBody: inkBody ?? this.inkBody,
      ink2: ink2 ?? this.ink2,
      ink3: ink3 ?? this.ink3,
      ink4: ink4 ?? this.ink4,
      rule: rule ?? this.rule,
      ruleStrong: ruleStrong ?? this.ruleStrong,
      accent: accent ?? this.accent,
      jade: jade ?? this.jade,
      gold: gold ?? this.gold,
    );
  }

  @override
  MojianTokens lerp(covariant MojianTokens? other, double t) {
    if (other == null) return this;
    Color c(Color a, Color b) => Color.lerp(a, b, t)!;
    return MojianTokens(
      paper: c(paper, other.paper),
      paper2: c(paper2, other.paper2),
      paper3: c(paper3, other.paper3),
      ink: c(ink, other.ink),
      inkBody: c(inkBody, other.inkBody),
      ink2: c(ink2, other.ink2),
      ink3: c(ink3, other.ink3),
      ink4: c(ink4, other.ink4),
      rule: c(rule, other.rule),
      ruleStrong: c(ruleStrong, other.ruleStrong),
      accent: c(accent, other.accent),
      jade: c(jade, other.jade),
      gold: c(gold, other.gold),
    );
  }
}

/// 墨笺的配色与组件主题。
class MojianTheme {
  MojianTheme._();

  /// 墨笺的 ColorScheme。所有 role 显式给出，不走 fromSeed：
  /// primary 是强调色（链接、选中、进度都取它），secondary 是中性墨色，
  /// 表面是纸色阶梯，surfaceTint 透明（不给抬高的表面染色）。
  static ColorScheme colorScheme(
    Brightness brightness,
    MojianAccent accent, {
    bool black = false,
    Color? accentColor,
  }) {
    final t = MojianTokens.of(
      brightness,
      accent,
      black: black,
      accentColor: accentColor,
    );
    final light = brightness == Brightness.light;
    final oled = !light && black;
    final onAccent = light ? const Color(0xFFFFF9F2) : t.paper;
    Color tint(Color c, double a) =>
        Color.alphaBlend(c.withValues(alpha: a), t.paper);
    return ColorScheme(
      brightness: brightness,
      primary: t.accent,
      onPrimary: onAccent,
      primaryContainer: tint(t.accent, light ? 0.13 : 0.22),
      onPrimaryContainer: Color.lerp(t.accent, t.ink, light ? 0.45 : 0.35)!,
      secondary: t.ink2,
      onSecondary: t.paper,
      // 纯黑下也压暗,别在黑底上浮出一块墨蓝
      secondaryContainer: light
          ? const Color(0xFFE9E2D5)
          : oled
          ? const Color(0xFF1E2228)
          : const Color(0xFF262D37),
      onSecondaryContainer: t.ink,
      tertiary: t.jade,
      onTertiary: onAccent,
      tertiaryContainer: tint(t.jade, light ? 0.14 : 0.22),
      onTertiaryContainer: Color.lerp(t.jade, t.ink, 0.4)!,
      error: light ? const Color(0xFFBA1A1A) : const Color(0xFFFFB4AB),
      onError: light ? const Color(0xFFFFFFFF) : const Color(0xFF690005),
      errorContainer: light ? const Color(0xFFFFDAD6) : const Color(0xFF93000A),
      onErrorContainer: light
          ? const Color(0xFF410002)
          : const Color(0xFFFFDAD6),
      surface: t.paper,
      onSurface: t.ink,
      onSurfaceVariant: t.ink3,
      surfaceDim: light
          ? const Color(0xFFE4DCCE)
          : oled
          ? const Color(0xFF000000)
          : const Color(0xFF0F1318),
      surfaceBright: light
          ? const Color(0xFFFBF8F2)
          : oled
          ? const Color(0xFF22262C)
          : const Color(0xFF2A313B),
      surfaceContainerLowest: light
          ? const Color(0xFFFBF8F2)
          : oled
          ? const Color(0xFF000000)
          : const Color(0xFF0D1015),
      surfaceContainerLow: light
          ? const Color(0xFFF3EEE5)
          : oled
          ? const Color(0xFF0A0B0D)
          : const Color(0xFF161A21),
      surfaceContainer: light
          ? const Color(0xFFEEE8DC)
          : oled
          ? const Color(0xFF101215)
          : const Color(0xFF1A1F27),
      surfaceContainerHigh: light
          ? const Color(0xFFE9E2D5)
          : oled
          ? const Color(0xFF16191D)
          : const Color(0xFF20262F),
      surfaceContainerHighest: light
          ? const Color(0xFFE3DBCD)
          : oled
          ? const Color(0xFF1E2228)
          : const Color(0xFF262D37),
      outline: light ? const Color(0xFF857D71) : const Color(0xFF736D63),
      outlineVariant: t.rule,
      inverseSurface: light ? t.inkBody : t.ink,
      onInverseSurface: light ? t.paper : const Color(0xFF12161C),
      inversePrimary: accent.of(light ? Brightness.dark : Brightness.light),
      // (自定义强调色时 inversePrimary 仍取预设的另一档:只用于反色 SnackBar 的按钮)
      surfaceTint: Colors.transparent,
      shadow: Colors.black,
      scrim: Colors.black,
    );
  }

  /// 墨笺的明暗两套配色（不支持透明背景）。[black] = 深色用纯黑(OLED)。
  ///
  /// [accentPair] 给出时(跟随壁纸取色)覆盖预设强调色的明/暗两档。
  static ResolvedTheme resolve(
    ThemeMode mode,
    MojianAccent accent, {
    bool black = false,
    (Color, Color)? accentPair,
  }) {
    return ResolvedTheme(
      light: colorScheme(Brightness.light, accent, accentColor: accentPair?.$1),
      dark: colorScheme(
        Brightness.dark,
        accent,
        black: black,
        accentColor: accentPair?.$2,
      ),
      mode: mode,
      transparent: false,
    );
  }

  /// 帖子正文的基础字样(短帖、长帖分段、嵌套楼层、话题预览共用一处,
  /// 段落预热按挂载处实际字样学习,各处必须同源)。
  /// 经典 = bodyMedium · 行高 1.5；墨笺 = 大一号、行高 1.72、正文墨色；
  /// Claude = 行高 1.6、正文深暖色。
  static TextStyle? postBodyStyle(ThemeData theme, double contentFontScale) {
    final base = theme.textTheme.bodyMedium;
    final size = (base?.fontSize ?? 14) * contentFontScale;
    final mj = theme.extension<MojianTokens>();
    if (mj != null) {
      return base?.copyWith(
        height: 1.72,
        fontSize: size * 15 / 14,
        color: mj.inkBody,
      );
    }
    final cl = theme.extension<ClaudeTokens>();
    if (cl != null) {
      return base?.copyWith(
        height: 1.6,
        fontSize: size,
        color: cl.textPrimary,
      );
    }
    return base?.copyWith(height: 1.5, fontSize: size);
  }

  /// 由任意种子色(系统壁纸取色)推出墨笺可用的强调色明/暗两档:保留色相,
  /// 饱和度封顶,明度逐步压暗 / 提亮到在纸色各层上对比度 ≥ 4.5:1。
  static (Color, Color) accentFromSeed(Color seed) {
    final hsl = HSLColor.fromColor(seed);
    final sat = math.min(hsl.saturation, 0.62);
    Color fit(Brightness b) {
      final light = b == Brightness.light;
      final bgs = [
        MojianTokens.of(b, MojianAccent.cinnabar).paper,
        MojianTokens.of(b, MojianAccent.cinnabar).paper2,
        MojianTokens.of(b, MojianAccent.cinnabar).paper3,
        MojianTokens.of(b, MojianAccent.cinnabar, black: true).paper,
        if (light) const Color(0xFFE9E2D5) else const Color(0xFF20262F),
      ];
      double minContrast(Color c) {
        final lc = c.computeLuminance();
        var worst = double.infinity;
        for (final bg in bgs) {
          final lb = bg.computeLuminance();
          final hi = math.max(lc, lb), lo = math.min(lc, lb);
          worst = math.min(worst, (hi + 0.05) / (lo + 0.05));
        }
        return worst;
      }

      var l = light ? 0.42 : 0.68;
      for (var i = 0; i < 60; i++) {
        final c = hsl.withSaturation(sat).withLightness(l).toColor();
        if (minContrast(c) >= 4.6) return c;
        l = light ? l - 0.01 : l + 0.01;
        if (l <= 0.05 || l >= 0.95) break;
      }
      return hsl.withSaturation(sat).withLightness(l.clamp(0.05, 0.95)).toColor();
    }

    return (fit(Brightness.light), fit(Brightness.dark));
  }

  /// 分类色块:服务端给的十六进制色;深色模式掺三成白,免得暗色分类在墨蓝底上看不见。
  static Color categoryColor(String hex, Brightness brightness) {
    final clean = hex.replaceAll('#', '');
    final c = clean.length == 6
        ? Color(int.parse('FF$clean', radix: 16))
        : const Color(0xFF9E9E9E);
    return brightness == Brightness.dark
        ? Color.lerp(c, const Color(0xFFFFFFFF), 0.3)!
        : c;
  }
  /// 标题类文字换成宋体：display / headline / titleLarge（AppBar 标题、对话框标题都走这里）。
  /// 正文、标签、按钮仍用用户选的正文字体。
  static TextTheme serifTitles(TextTheme base) {
    TextStyle? serif(TextStyle? s, FontWeight w) => s?.copyWith(
      fontFamily: MojianTokens.serifFamily,
      fontWeight: w,
      letterSpacing: 0.2,
    );
    return base.copyWith(
      displayLarge: serif(base.displayLarge, FontWeight.w700),
      displayMedium: serif(base.displayMedium, FontWeight.w700),
      displaySmall: serif(base.displaySmall, FontWeight.w700),
      headlineLarge: serif(base.headlineLarge, FontWeight.w700),
      headlineMedium: serif(base.headlineMedium, FontWeight.w700),
      headlineSmall: serif(base.headlineSmall, FontWeight.w600),
      titleLarge: serif(base.titleLarge, FontWeight.w600),
    );
  }

  /// 组装墨笺的 ThemeData。页面转场、图标主题、额外扩展由调用方传入，
  /// 与经典风格共用同一套（两种风格只在配色与组件外观上不同）。
  static ThemeData build({
    required ColorScheme scheme,
    required MojianAccent accent,
    required String? fontFamily,
    required PageTransitionsTheme pageTransitionsTheme,
    required IconThemeData iconTheme,
    required IconThemeData primaryIconTheme,
    List<ThemeExtension<dynamic>> extensions = const [],
  }) {
    // 纯黑由配色带进来(深色且底色为纯黑),令牌跟着取同一套
    final black =
        scheme.brightness == Brightness.dark &&
        scheme.surface.toARGB32() == 0xFF000000;
    // 强调色以配色里的 primary 为准(跟随壁纸取色时不等于预设)
    final t = MojianTokens.of(
      scheme.brightness,
      accent,
      black: black,
      accentColor: scheme.primary,
    );
    final stadium = WidgetStatePropertyAll<OutlinedBorder>(
      const StadiumBorder(),
    );
    final base = ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      fontFamily: fontFamily,
      scaffoldBackgroundColor: t.paper,
      canvasColor: t.paper,
      dividerColor: t.rule,
      pageTransitionsTheme: pageTransitionsTheme,
      iconTheme: iconTheme,
      primaryIconTheme: primaryIconTheme,
      extensions: [
        ...extensions,
        t,
        // 帖子正文:引用块改 2px 强调色竖条、无底色;小标题用宋体
        FluxdoRenderStyle(
          quoteBarColor: t.accent.withValues(alpha: 0.75),
          quoteBarWidth: 2,
          quoteBackground: Colors.transparent,
          quoteRadius: 0,
          quoteTextColor: t.ink2,
          quoteFontFamily: MojianTokens.serifFamily,
          headingFontFamily: MojianTokens.serifFamily,
          headingColor: t.ink,
          ruleColor: t.rule,
        ),
        // 设置、我的、会话列表等分段卡片组:平铺细线列表
        SegmentedCardStyle(flat: true, dividerColor: t.rule),
        // 菜单顶部快捷按钮:细线圆圈,选中描强调色、底色极淡
        MenuQuickActionStyle(
          fill: Colors.transparent,
          activeFill: t.accentSoft,
          iconColor: t.ink2,
          activeIconColor: t.accent,
          border: t.ruleStrong,
          activeBorder: t.accent.withValues(alpha: 0.6),
        ),
      ],
      appBarTheme: AppBarThemeData(
        backgroundColor: t.paper,
        foregroundColor: t.ink,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: t.paper3,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(color: t.rule),
        ),
      ),
      dividerTheme: DividerThemeData(color: t.rule, thickness: 1, space: 1),
      filledButtonTheme: FilledButtonThemeData(
        style: ButtonStyle(
          backgroundColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.disabled)
                ? t.ink.withValues(alpha: 0.12)
                : t.ink,
          ),
          foregroundColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.disabled)
                ? t.ink.withValues(alpha: 0.38)
                : t.paper,
          ),
          overlayColor: WidgetStatePropertyAll(t.paper.withValues(alpha: 0.1)),
          shape: stadium,
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ButtonStyle(
          elevation: const WidgetStatePropertyAll(0),
          backgroundColor: WidgetStatePropertyAll(scheme.surfaceContainerHigh),
          foregroundColor: WidgetStatePropertyAll(t.ink),
          shape: stadium,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: ButtonStyle(
          foregroundColor: WidgetStatePropertyAll(t.ink2),
          side: WidgetStateProperty.resolveWith(
            (s) => BorderSide(
              color: s.contains(WidgetState.disabled) ? t.rule : t.ruleStrong,
            ),
          ),
          shape: stadium,
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: t.ink,
        foregroundColor: t.paper,
        elevation: 3,
        focusElevation: 3,
        hoverElevation: 4,
        highlightElevation: 2,
        shape: const StadiumBorder(),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: Colors.transparent,
        selectedColor: t.ink,
        checkmarkColor: t.paper,
        side: WidgetStateBorderSide.resolveWith(
          (s) => BorderSide(
            color: s.contains(WidgetState.selected) ? t.ink : t.rule,
          ),
        ),
        shape: const StadiumBorder(),
        // 颜色要用 WidgetStateColor:RawChip 会先把 labelStyle 与组件自带样式
        // merge(WidgetStateTextStyle 的解析器在 merge 时丢失),再只对 color
        // 做状态解析。用 WidgetStateTextStyle 时未选中标签会落成纸色、看不见
        labelStyle: TextStyle(
          color: WidgetStateColor.resolveWith(
            (s) => s.contains(WidgetState.disabled)
                ? t.ink4
                : s.contains(WidgetState.selected)
                ? t.paper
                : t.ink2,
          ),
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? t.paper : scheme.outline,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected)
              ? t.ink
              : scheme.surfaceContainerHighest,
        ),
        trackOutlineColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? t.ink : scheme.outline,
        ),
      ),
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? t.ink : null,
        ),
        checkColor: WidgetStatePropertyAll(t.paper),
      ),
      radioTheme: RadioThemeData(
        fillColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? t.ink : scheme.outline,
        ),
      ),
      tabBarTheme: TabBarThemeData(
        indicator: _ShortBarIndicator(color: t.accent),
        indicatorSize: TabBarIndicatorSize.label,
        labelColor: t.ink,
        unselectedLabelColor: t.ink3,
        dividerColor: t.rule,
        labelStyle: const TextStyle(fontWeight: FontWeight.w600),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: t.paper,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        // 选中记号是顶边的强调色短横(见 adaptive_navigation 的 _MojianNavFrame)
        indicatorColor: Colors.transparent,
        iconTheme: WidgetStateProperty.resolveWith(
          (s) => IconThemeData(
            color: s.contains(WidgetState.selected) ? t.ink : t.ink3,
          ),
        ),
        labelTextStyle: WidgetStateProperty.resolveWith(
          (s) => TextStyle(
            fontSize: 11,
            letterSpacing: 0.3,
            color: s.contains(WidgetState.selected) ? t.ink : t.ink3,
            fontWeight: s.contains(WidgetState.selected)
                ? FontWeight.w600
                : FontWeight.w400,
          ),
        ),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: t.paper,
        indicatorColor: scheme.secondaryContainer,
        selectedIconTheme: IconThemeData(color: t.ink),
        unselectedIconTheme: IconThemeData(color: t.ink3),
        selectedLabelTextStyle: TextStyle(
          color: t.ink,
          fontWeight: FontWeight.w600,
        ),
        unselectedLabelTextStyle: TextStyle(color: t.ink3),
      ),
      // 只给缺省的 border(下划线):页面自己写了 border(圆角填色搜索框
      // 之类)时整套覆盖,不会被主题的 enabledBorder 硬叠一道下划线
      inputDecorationTheme: InputDecorationThemeData(
        border: UnderlineInputBorder(
          borderSide: BorderSide(color: t.ruleStrong),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: t.paper3,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: t.paper3,
        modalBackgroundColor: t.paper3,
        surfaceTintColor: Colors.transparent,
        dragHandleColor: t.ruleStrong,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        elevation: 3,
        color: t.paper3,
        surfaceTintColor: Colors.transparent,
        menuPadding: const EdgeInsets.symmetric(vertical: 6),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: scheme.inverseSurface,
        actionTextColor: scheme.inversePrimary,
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
        selectionColor: t.accent.withValues(alpha: 0.22),
        selectionHandleColor: t.accent,
      ),
      scrollbarTheme: ScrollbarThemeData(
        thumbColor: WidgetStatePropertyAll(t.ruleStrong),
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
    final textTheme = serifTitles(base.textTheme);
    return base.copyWith(
      textTheme: textTheme,
      appBarTheme: base.appBarTheme.copyWith(
        titleTextStyle: textTheme.titleLarge?.copyWith(
          fontSize: 19,
          color: t.ink,
        ),
      ),
      dialogTheme: base.dialogTheme.copyWith(
        titleTextStyle: textTheme.headlineSmall?.copyWith(
          fontSize: 20,
          color: t.ink,
        ),
      ),
    );
  }
}

/// 选中标签下方居中的一小段强调色短横（墨笺的标签指示器）。
class _ShortBarIndicator extends Decoration {
  const _ShortBarIndicator({required this.color});

  final Color color;

  @override
  BoxPainter createBoxPainter([VoidCallback? onChanged]) =>
      _ShortBarPainter(color);
}

class _ShortBarPainter extends BoxPainter {
  _ShortBarPainter(this.color);

  final Color color;
  static const _width = 18.0;
  static const _height = 2.0;

  @override
  void paint(Canvas canvas, Offset offset, ImageConfiguration configuration) {
    final size = configuration.size;
    if (size == null) return;
    final w = math.min(_width, size.width);
    final rect = Rect.fromLTWH(
      offset.dx + (size.width - w) / 2,
      offset.dy + size.height - _height,
      w,
      _height,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(_height)),
      Paint()..color = color,
    );
  }
}
