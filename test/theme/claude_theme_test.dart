import 'package:common_ui/common_ui.dart' show MenuQuickActionStyle;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/theme/app_background.dart';
import 'package:fluxdo/theme/claude_theme.dart';
import 'package:fluxdo/theme/mojian_theme.dart';
import 'package:fluxdo_render/fluxdo_render.dart' show FluxdoRenderStyle;
import 'package:m3e_ui/m3e_ui.dart' show SegmentedCardStyle;
import 'package:shared_preferences/shared_preferences.dart';

double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Claude 界面风格状态', () {
    test('切换到 Claude 风格会落盘 ui_style=claude', () async {
      SharedPreferences.setMockInitialValues({
        'onboarding_completed': true,
        'ui_style': 'mojian',
      });
      final prefs = await SharedPreferences.getInstance();
      final n = ThemeNotifier(prefs);
      expect(n.state.uiStyle, UiStyle.mojian);
      expect(n.state.isClaude, isFalse);

      await n.setUiStyle(UiStyle.claude);
      expect(n.state.uiStyle, UiStyle.claude);
      expect(n.state.isClaude, isTrue);
      expect(n.state.isMojian, isFalse);
      expect(n.state.isClassic, isFalse);
      expect(prefs.getString('ui_style'), 'claude');
      expect(n.state.effectiveSeedColor, const Color(0xFFDA7756));
    });

    test('Claude 风格下透明背景不生效，经典下照旧', () {
      const bg = AppBackground(imagePath: '/tmp/bg.png');
      const base = ThemeState(
        mode: ThemeMode.system,
        seedColor: Colors.blue,
        transparentEnabled: true,
        background: bg,
        uiStyle: UiStyle.claude,
      );
      expect(base.isTransparentActive, isFalse);
      expect(
        base.copyWith(uiStyle: UiStyle.classic).isTransparentActive,
        isTrue,
      );
    });
  });

  group('Claude 配色与对比度', () {
    for (final brightness in Brightness.values) {
      test('${brightness.name}：文本与核心元素对比度达标', () {
        final s = ClaudeTheme.colorScheme(brightness);
        final t = ClaudeTokens.of(brightness);
        expect(s.brightness, brightness);

        for (final bg in [
          s.surface,
          s.surfaceContainerLow,
          s.surfaceContainer,
          s.surfaceContainerHigh,
        ]) {
          // 主要文本对比度 >= 7.0 (AAA)
          expect(_contrast(s.onSurface, bg), greaterThanOrEqualTo(7.0));
          // 次要文本对比度 >= 4.5 (AA)
          expect(_contrast(s.onSurfaceVariant, bg), greaterThanOrEqualTo(4.5));
        }

        if (brightness == Brightness.dark) {
          // 暗色下陶土红在深色底上的对比度 >= 4.5
          expect(_contrast(s.primary, s.surface), greaterThanOrEqualTo(4.5));
          expect(_contrast(s.onPrimary, s.primary), greaterThanOrEqualTo(4.5));
        }

        expect(s.surfaceTint, Colors.transparent);
        expect(t.accent, s.primary);
      });
    }

    test('纯黑：深色底换为 OLED 纯黑，各层表面对比度仍达标；浅色不受影响', () {
      final s = ClaudeTheme.colorScheme(Brightness.dark, black: true);
      final t = ClaudeTokens.of(Brightness.dark, black: true);
      expect(s.surface, const Color(0xFF000000));
      expect(t.background, const Color(0xFF000000));

      for (final bg in [
        s.surface,
        s.surfaceContainerLow,
        s.surfaceContainer,
        s.surfaceContainerHigh,
      ]) {
        expect(_contrast(s.onSurface, bg), greaterThanOrEqualTo(7.0));
        expect(_contrast(s.onSurfaceVariant, bg), greaterThanOrEqualTo(4.5));
      }
      expect(_contrast(s.primary, s.surface), greaterThanOrEqualTo(4.5));

      // 浅色模式不受 black 参数影响
      final sLight = ClaudeTheme.colorScheme(Brightness.light, black: true);
      expect(sLight.surface, const Color(0xFFFAF8F5));
    });

    test('令牌插值两端取值正确', () {
      final a = ClaudeTokens.of(Brightness.light);
      final b = ClaudeTokens.of(Brightness.dark);
      expect(a.lerp(b, 0).background, a.background);
      expect(a.lerp(b, 1).background, b.background);
      expect(a.lerp(b, 0).accent, a.accent);
      expect(a.lerp(b, 1).accent, b.accent);
      expect(a.lerp(null, 0.5), same(a));
    });
  });

  group('Claude 扩展样式注入', () {
    test('Claude 主题注入菜单快捷按钮与平铺分段卡片样式', () {
      final theme = ClaudeTheme.build(
        scheme: ClaudeTheme.colorScheme(Brightness.light),
        fontFamily: null,
        pageTransitionsTheme: const PageTransitionsTheme(),
        iconTheme: const IconThemeData(),
        primaryIconTheme: const IconThemeData(),
      );

      final menuStyle = theme.extension<MenuQuickActionStyle>();
      expect(menuStyle, isNotNull);
      expect(menuStyle!.fill, Colors.transparent);
      expect(menuStyle.border, isNotNull);

      final cardStyle = theme.extension<SegmentedCardStyle>();
      expect(cardStyle, isNotNull);
      expect(cardStyle!.flat, isTrue);
    });

    testWidgets('选择标签：未选中次要文字色、选中时为强调色', (tester) async {
      final theme = ClaudeTheme.build(
        scheme: ClaudeTheme.colorScheme(Brightness.light),
        fontFamily: null,
        pageTransitionsTheme: const PageTransitionsTheme(),
        iconTheme: const IconThemeData(),
        primaryIconTheme: const IconThemeData(),
      );
      final t = theme.extension<ClaudeTokens>()!;

      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: Scaffold(
            body: Row(
              children: [
                ChoiceChip(
                  label: const Text('on'),
                  selected: true,
                  onSelected: (_) {},
                ),
                ChoiceChip(
                  label: const Text('off'),
                  selected: false,
                  onSelected: (_) {},
                ),
              ],
            ),
          ),
        ),
      );

      Color? colorOf(String label) {
        final rich = tester.widget<RichText>(
          find.descendant(
            of: find.text(label),
            matching: find.byType(RichText),
          ),
        );
        return rich.text.style?.color;
      }

      expect(colorOf('on'), t.accent);
      expect(colorOf('off'), t.textSecondary);
    });
  });

  group('Claude 字体沿用全局设置', () {
    for (final brightness in Brightness.values) {
      test('${brightness.name}：默认不指定字体时，所有文本样式不强制任何字体族', () {
        final scheme = ClaudeTheme.colorScheme(brightness);
        final theme = ClaudeTheme.build(
          scheme: scheme,
          fontFamily: null,
          pageTransitionsTheme: const PageTransitionsTheme(),
          iconTheme: const IconThemeData(),
          primaryIconTheme: const IconThemeData(),
        );

        expect(theme.colorScheme, scheme);
        expect(theme.scaffoldBackgroundColor, scheme.surface);
        // 标题与正文均不被强制指定特定字体族（例如宋体 MojianSerif）
        expect(
          theme.textTheme.titleLarge?.fontFamily,
          isNot(MojianTokens.serifFamily),
        );
        expect(
          theme.textTheme.headlineSmall?.fontFamily,
          isNot(MojianTokens.serifFamily),
        );
        expect(
          theme.textTheme.bodyMedium?.fontFamily,
          isNot(MojianTokens.serifFamily),
        );
        expect(theme.appBarTheme.titleTextStyle?.fontFamily, isNull);

        // 正文渲染配置中也不硬编码标题字体族
        final rs = theme.extension<FluxdoRenderStyle>();
        expect(rs, isNotNull);
        expect(rs?.headingFontFamily, isNull);
        expect(rs?.quoteFontFamily, isNull);
        expect(rs?.quoteBarColor, ClaudeTokens.of(brightness).accent);

        // 正文字体样式采用舒适的 1.6 行高与深暖色
        final postStyle = MojianTheme.postBodyStyle(theme, 1.0);
        expect(postStyle?.height, 1.6);
        expect(postStyle?.color, ClaudeTokens.of(brightness).textPrimary);
      });

      test('${brightness.name}：全局指定自定义字体时，标题与组件统一继承该字体', () {
        const customFont = 'MiSans';
        final scheme = ClaudeTheme.colorScheme(brightness);
        final theme = ClaudeTheme.build(
          scheme: scheme,
          fontFamily: customFont,
          pageTransitionsTheme: const PageTransitionsTheme(),
          iconTheme: const IconThemeData(),
          primaryIconTheme: const IconThemeData(),
        );

        expect(theme.textTheme.titleLarge?.fontFamily, customFont);
        expect(theme.textTheme.headlineSmall?.fontFamily, customFont);
        expect(theme.textTheme.bodyMedium?.fontFamily, customFont);
        expect(theme.appBarTheme.titleTextStyle?.fontFamily, customFont);
        expect(theme.dialogTheme.titleTextStyle?.fontFamily, customFont);
      });
    }
  });
}
