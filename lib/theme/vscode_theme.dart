import 'package:common_ui/common_ui.dart' show MenuQuickActionStyle;
import 'package:flutter/material.dart';
import 'package:fluxdo_render/fluxdo_render.dart' show FluxdoRenderStyle;
import 'package:m3e_ui/m3e_ui.dart' show SegmentedCardStyle;

import 'theme_resolver.dart';

/// Windows 编辑器界面的固定配色，不受调色板、纯黑或壁纸设置影响。
@immutable
class VscodeTokens extends ThemeExtension<VscodeTokens> {
  const VscodeTokens({
    required this.background,
    required this.sidebar,
    required this.panel,
    required this.foreground,
    required this.muted,
    required this.border,
    required this.accent,
    required this.selection,
    required this.hover,
    required this.lineNumber,
    required this.syntaxKeyword,
    required this.syntaxString,
    required this.syntaxComment,
    required this.syntaxType,
    required this.syntaxFunction,
  });

  final Color background;
  final Color sidebar;
  final Color panel;
  final Color foreground;
  final Color muted;
  final Color border;
  final Color accent;
  final Color selection;
  final Color hover;
  final Color lineNumber;
  final Color syntaxKeyword;
  final Color syntaxString;
  final Color syntaxComment;
  final Color syntaxType;
  final Color syntaxFunction;

  static VscodeTokens? maybeOf(BuildContext context) =>
      Theme.of(context).extension<VscodeTokens>();

  static VscodeTokens of(Brightness brightness) =>
      brightness == Brightness.light
      ? const VscodeTokens(
          background: Color(0xFFFFFFFF),
          sidebar: Color(0xFFF8F8F8),
          panel: Color(0xFFF8F8F8),
          foreground: Color(0xFF3B3B3B),
          muted: Color(0xFF616161),
          border: Color(0xFFE5E5E5),
          accent: Color(0xFF005FB8),
          selection: Color(0xFFADD6FF),
          hover: Color(0xFFE8E8E8),
          lineNumber: Color(0xFF6E7681),
          syntaxKeyword: Color(0xFF0000FF),
          syntaxString: Color(0xFFA31515),
          syntaxComment: Color(0xFF008000),
          syntaxType: Color(0xFF267F99),
          syntaxFunction: Color(0xFF795E26),
        )
      : const VscodeTokens(
          background: Color(0xFF1F1F1F),
          sidebar: Color(0xFF181818),
          panel: Color(0xFF181818),
          foreground: Color(0xFFCCCCCC),
          muted: Color(0xFF9D9D9D),
          border: Color(0xFF2B2B2B),
          accent: Color(0xFF0078D4),
          selection: Color(0xFF264F78),
          hover: Color(0xFF2A2D2E),
          lineNumber: Color(0xFF858585),
          syntaxKeyword: Color(0xFF569CD6),
          syntaxString: Color(0xFFCE9178),
          syntaxComment: Color(0xFF6A9955),
          syntaxType: Color(0xFF4EC9B0),
          syntaxFunction: Color(0xFFDCDCAA),
        );

  @override
  VscodeTokens copyWith({
    Color? background,
    Color? sidebar,
    Color? panel,
    Color? foreground,
    Color? muted,
    Color? border,
    Color? accent,
    Color? selection,
    Color? hover,
    Color? lineNumber,
    Color? syntaxKeyword,
    Color? syntaxString,
    Color? syntaxComment,
    Color? syntaxType,
    Color? syntaxFunction,
  }) => VscodeTokens(
    background: background ?? this.background,
    sidebar: sidebar ?? this.sidebar,
    panel: panel ?? this.panel,
    foreground: foreground ?? this.foreground,
    muted: muted ?? this.muted,
    border: border ?? this.border,
    accent: accent ?? this.accent,
    selection: selection ?? this.selection,
    hover: hover ?? this.hover,
    lineNumber: lineNumber ?? this.lineNumber,
    syntaxKeyword: syntaxKeyword ?? this.syntaxKeyword,
    syntaxString: syntaxString ?? this.syntaxString,
    syntaxComment: syntaxComment ?? this.syntaxComment,
    syntaxType: syntaxType ?? this.syntaxType,
    syntaxFunction: syntaxFunction ?? this.syntaxFunction,
  );

  @override
  VscodeTokens lerp(covariant VscodeTokens? other, double t) {
    if (other == null) return this;
    Color c(Color a, Color b) => Color.lerp(a, b, t)!;
    return VscodeTokens(
      background: c(background, other.background),
      sidebar: c(sidebar, other.sidebar),
      panel: c(panel, other.panel),
      foreground: c(foreground, other.foreground),
      muted: c(muted, other.muted),
      border: c(border, other.border),
      accent: c(accent, other.accent),
      selection: c(selection, other.selection),
      hover: c(hover, other.hover),
      lineNumber: c(lineNumber, other.lineNumber),
      syntaxKeyword: c(syntaxKeyword, other.syntaxKeyword),
      syntaxString: c(syntaxString, other.syntaxString),
      syntaxComment: c(syntaxComment, other.syntaxComment),
      syntaxType: c(syntaxType, other.syntaxType),
      syntaxFunction: c(syntaxFunction, other.syntaxFunction),
    );
  }
}

/// Light Modern / Dark Modern：平面、小圆角、紧凑，不注入 M3E 动效。
class VscodeTheme {
  VscodeTheme._();

  static const codeFontFamily = 'Consolas';

  /// 代码正文、作者工具条与楼层操作共用起始位置，字号变化时一起缩放。
  static double sourceTextInset(double fontScale) => 44 * fontScale + 12;

  /// 等宽字体先匹配拉丁文字，中文仍沿用全局字体并由系统兜底。
  static List<String> codeFontFallback(String? fontFamily) => [
    'Cascadia Mono',
    'monospace',
    if (fontFamily != null) fontFamily,
    'Microsoft YaHei UI',
    'Microsoft YaHei',
  ];

  static ColorScheme colorScheme(Brightness brightness) {
    final t = VscodeTokens.of(brightness);
    final light = brightness == Brightness.light;
    final error = light ? const Color(0xFFE51400) : const Color(0xFFF48771);
    return ColorScheme(
      brightness: brightness,
      primary: t.accent,
      onPrimary: Colors.white,
      primaryContainer: t.selection,
      onPrimaryContainer: t.foreground,
      secondary: t.muted,
      onSecondary: light ? Colors.white : t.sidebar,
      secondaryContainer: t.hover,
      onSecondaryContainer: t.foreground,
      tertiary: t.syntaxComment,
      onTertiary: Colors.white,
      tertiaryContainer: t.hover,
      onTertiaryContainer: t.foreground,
      error: error,
      onError: light ? Colors.white : t.sidebar,
      errorContainer: light ? const Color(0xFFFDE7E9) : const Color(0xFF3B2222),
      onErrorContainer: light
          ? const Color(0xFF9D1111)
          : const Color(0xFFF48771),
      surface: t.background,
      onSurface: t.foreground,
      onSurfaceVariant: t.muted,
      surfaceDim: t.sidebar,
      surfaceBright: light ? Colors.white : const Color(0xFF2B2B2B),
      surfaceContainerLowest: t.sidebar,
      surfaceContainerLow: t.panel,
      surfaceContainer: t.panel,
      surfaceContainerHigh: t.hover,
      surfaceContainerHighest: t.hover,
      outline: t.lineNumber,
      outlineVariant: t.border,
      inverseSurface: light ? const Color(0xFF1F1F1F) : const Color(0xFFF8F8F8),
      onInverseSurface: light
          ? const Color(0xFFCCCCCC)
          : const Color(0xFF3B3B3B),
      inversePrimary: light ? const Color(0xFF4DAAFC) : const Color(0xFF005FB8),
      surfaceTint: Colors.transparent,
      shadow: Colors.black,
      scrim: Colors.black,
    );
  }

  static ResolvedTheme resolve(ThemeMode mode) => ResolvedTheme(
    light: colorScheme(Brightness.light),
    dark: colorScheme(Brightness.dark),
    mode: mode,
    transparent: false,
  );

  /// 工作区工具栏独立于正文密度，确保菜单与普通按钮占用相同几何空间。
  static ThemeData toolbarTheme(ThemeData theme) {
    const iconStyle = ButtonStyle(
      fixedSize: WidgetStatePropertyAll(Size(32, 32)),
      minimumSize: WidgetStatePropertyAll(Size(32, 32)),
      maximumSize: WidgetStatePropertyAll(Size(32, 32)),
      iconSize: WidgetStatePropertyAll(16),
      padding: WidgetStatePropertyAll(EdgeInsets.zero),
      visualDensity: VisualDensity.standard,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
    const textStyle = ButtonStyle(
      minimumSize: WidgetStatePropertyAll(Size(0, 32)),
      padding: WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 8)),
      visualDensity: VisualDensity.standard,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      textStyle: WidgetStatePropertyAll(TextStyle(fontSize: 11, height: 1.2)),
      shape: WidgetStatePropertyAll(RoundedRectangleBorder()),
    );
    return theme.copyWith(
      visualDensity: VisualDensity.standard,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      iconTheme: theme.iconTheme.copyWith(size: 16),
      iconButtonTheme: IconButtonThemeData(
        style: theme.iconButtonTheme.style?.merge(iconStyle) ?? iconStyle,
      ),
      popupMenuTheme: theme.popupMenuTheme.copyWith(iconSize: 16),
      textButtonTheme: TextButtonThemeData(
        style: theme.textButtonTheme.style?.merge(textStyle) ?? textStyle,
      ),
    );
  }

  static ThemeData build({
    required ColorScheme scheme,
    required String? fontFamily,
    required PageTransitionsTheme pageTransitionsTheme,
    required IconThemeData iconTheme,
    required IconThemeData primaryIconTheme,
    List<ThemeExtension<dynamic>> extensions = const [],
  }) {
    final t = VscodeTokens.of(scheme.brightness);
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(3),
    );
    final buttonShape = WidgetStatePropertyAll<OutlinedBorder>(shape);
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      fontFamily: fontFamily,
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
    OutlineInputBorder inputBorder(Color color) => OutlineInputBorder(
      borderRadius: BorderRadius.circular(2),
      borderSide: BorderSide(color: color),
    );
    return base.copyWith(
      scaffoldBackgroundColor: t.background,
      canvasColor: t.background,
      cardColor: t.panel,
      dividerColor: t.border,
      hoverColor: t.hover,
      focusColor: t.selection,
      splashFactory: NoSplash.splashFactory,
      pageTransitionsTheme: pageTransitionsTheme,
      iconTheme: iconTheme,
      primaryIconTheme: primaryIconTheme,
      textTheme: base.textTheme
          .copyWith(
            bodyLarge: base.textTheme.bodyLarge?.copyWith(fontSize: 14),
            bodyMedium: base.textTheme.bodyMedium?.copyWith(fontSize: 13),
            bodySmall: base.textTheme.bodySmall?.copyWith(fontSize: 12),
            titleLarge: base.textTheme.titleLarge?.copyWith(fontSize: 18),
            titleMedium: base.textTheme.titleMedium?.copyWith(fontSize: 14),
            titleSmall: base.textTheme.titleSmall?.copyWith(fontSize: 13),
          )
          .apply(bodyColor: t.foreground, displayColor: t.foreground),
      extensions: [
        ...extensions,
        t,
        FluxdoRenderStyle(
          quoteBarColor: t.border,
          quoteBarWidth: 1,
          quoteBackground: t.panel,
          quoteRadius: 0,
          quoteTextColor: t.muted,
          quoteFontFamily: codeFontFamily,
          headingFontFamily: codeFontFamily,
          headingColor: t.syntaxKeyword,
          ruleColor: t.border,
        ),
        SegmentedCardStyle(flat: true, dividerColor: t.border),
        MenuQuickActionStyle(
          fill: Colors.transparent,
          activeFill: t.selection,
          iconColor: t.muted,
          activeIconColor: t.foreground,
          border: t.border,
          activeBorder: t.accent,
        ),
      ],
      appBarTheme: AppBarThemeData(
        backgroundColor: t.panel,
        foregroundColor: t.foreground,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        toolbarHeight: 40,
        titleTextStyle: TextStyle(
          fontFamily: fontFamily,
          fontSize: 13,
          color: t.foreground,
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: t.panel,
        surfaceTintColor: Colors.transparent,
        margin: EdgeInsets.zero,
        shape: shape.copyWith(side: BorderSide(color: t.border)),
      ),
      dividerTheme: DividerThemeData(color: t.border, thickness: 1, space: 1),
      filledButtonTheme: FilledButtonThemeData(
        style: ButtonStyle(
          shape: buttonShape,
          elevation: const WidgetStatePropertyAll(0),
          minimumSize: const WidgetStatePropertyAll(Size(64, 28)),
          padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          ),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ButtonStyle(
          shape: buttonShape,
          elevation: const WidgetStatePropertyAll(0),
          backgroundColor: WidgetStatePropertyAll(t.hover),
          foregroundColor: WidgetStatePropertyAll(t.foreground),
          minimumSize: const WidgetStatePropertyAll(Size(64, 28)),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: ButtonStyle(
          shape: buttonShape,
          foregroundColor: WidgetStatePropertyAll(t.foreground),
          side: WidgetStatePropertyAll(BorderSide(color: t.border)),
          minimumSize: const WidgetStatePropertyAll(Size(64, 28)),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: ButtonStyle(
          shape: buttonShape,
          minimumSize: const WidgetStatePropertyAll(Size(48, 28)),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: ButtonStyle(
          shape: buttonShape,
          iconSize: const WidgetStatePropertyAll(18),
          minimumSize: const WidgetStatePropertyAll(Size(28, 28)),
          padding: const WidgetStatePropertyAll(EdgeInsets.all(4)),
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        shape: shape,
        elevation: 0,
        hoverElevation: 0,
        focusElevation: 0,
        highlightElevation: 0,
        backgroundColor: t.accent,
        foregroundColor: Colors.white,
      ),
      chipTheme: ChipThemeData(
        shape: shape,
        side: BorderSide(color: t.border),
        backgroundColor: t.panel,
        selectedColor: t.selection,
        labelStyle: TextStyle(color: t.foreground, fontSize: 12),
        padding: const EdgeInsets.symmetric(horizontal: 4),
      ),
      checkboxTheme: CheckboxThemeData(
        shape: shape,
        side: BorderSide(color: t.muted),
      ),
      switchTheme: SwitchThemeData(
        trackColor: WidgetStateProperty.resolveWith(
          (states) =>
              states.contains(WidgetState.selected) ? t.accent : t.hover,
        ),
        thumbColor: WidgetStatePropertyAll(
          scheme.brightness == Brightness.light ? Colors.white : t.foreground,
        ),
        trackOutlineColor: WidgetStatePropertyAll(t.border),
      ),
      inputDecorationTheme: InputDecorationThemeData(
        isDense: true,
        filled: true,
        fillColor: t.background,
        contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
        border: inputBorder(t.border),
        enabledBorder: inputBorder(t.border),
        focusedBorder: inputBorder(t.accent),
        errorBorder: inputBorder(scheme.error),
        focusedErrorBorder: inputBorder(scheme.error),
      ),
      listTileTheme: ListTileThemeData(
        dense: true,
        minVerticalPadding: 4,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12),
        iconColor: t.muted,
        textColor: t.foreground,
        selectedColor: t.foreground,
        selectedTileColor: t.selection,
        shape: const RoundedRectangleBorder(),
      ),
      tabBarTheme: TabBarThemeData(
        labelColor: t.foreground,
        unselectedLabelColor: t.muted,
        dividerColor: t.border,
        indicator: UnderlineTabIndicator(
          borderSide: BorderSide(color: t.accent),
        ),
        labelStyle: const TextStyle(fontSize: 13),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: t.sidebar,
        indicatorColor: Colors.transparent,
        selectedIconTheme: IconThemeData(color: t.foreground, size: 22),
        unselectedIconTheme: IconThemeData(color: t.muted, size: 22),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: t.sidebar,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        indicatorColor: t.selection,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: t.panel,
        surfaceTintColor: Colors.transparent,
        shape: shape.copyWith(side: BorderSide(color: t.border)),
        titleTextStyle: TextStyle(
          fontFamily: fontFamily,
          fontSize: 16,
          color: t.foreground,
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: t.panel,
        modalBackgroundColor: t.panel,
        surfaceTintColor: Colors.transparent,
        shape: shape,
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: t.panel,
        surfaceTintColor: Colors.transparent,
        shape: shape.copyWith(side: BorderSide(color: t.border)),
        elevation: 2,
        textStyle: TextStyle(
          fontFamily: fontFamily,
          color: t.foreground,
          fontSize: 13,
        ),
      ),
      menuTheme: MenuThemeData(
        style: MenuStyle(
          backgroundColor: WidgetStatePropertyAll(t.panel),
          surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
          shape: buttonShape,
          side: WidgetStatePropertyAll(BorderSide(color: t.border)),
          padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(vertical: 4),
          ),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: t.panel,
        contentTextStyle: TextStyle(
          fontFamily: fontFamily,
          color: t.foreground,
          fontSize: 13,
        ),
        actionTextColor: t.accent,
        shape: shape.copyWith(side: BorderSide(color: t.border)),
        elevation: 0,
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: t.panel,
          border: Border.all(color: t.border),
        ),
        textStyle: TextStyle(
          fontFamily: fontFamily,
          color: t.foreground,
          fontSize: 12,
        ),
      ),
      badgeTheme: BadgeThemeData(
        backgroundColor: t.accent,
        textColor: Colors.white,
      ),
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: t.accent,
        selectionColor: t.selection,
        selectionHandleColor: t.accent,
      ),
      scrollbarTheme: ScrollbarThemeData(
        radius: Radius.zero,
        thickness: const WidgetStatePropertyAll(10),
        thumbColor: WidgetStatePropertyAll(t.lineNumber.withValues(alpha: 0.4)),
      ),
      // ignore: deprecated_member_use
      sliderTheme: const SliderThemeData(year2023: true),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        // ignore: deprecated_member_use
        year2023: true,
        circularTrackPadding: EdgeInsets.zero,
      ),
    );
  }
}
