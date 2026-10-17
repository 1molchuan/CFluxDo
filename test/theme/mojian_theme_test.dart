import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/theme/app_background.dart';
import 'package:fluxdo/theme/mojian_theme.dart';
import 'package:fluxdo_render/fluxdo_render.dart' show FluxdoRenderStyle;
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

  group('界面风格设置', () {
    test('新装：默认墨笺 + 朱砂，并把风格落盘，不提示', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final n = ThemeNotifier(prefs);
      expect(n.state.uiStyle, UiStyle.mojian);
      expect(n.state.mojianAccent, MojianAccent.cinnabar);
      expect(prefs.getString('ui_style'), 'mojian');
      expect(n.consumeMojianIntro(), isFalse);
    });

    test('老用户升级：默认墨笺，提示一次', () async {
      SharedPreferences.setMockInitialValues({
        'onboarding_completed': true,
        'theme_mode': 'dark',
        'palette_id': 'ocean',
      });
      final prefs = await SharedPreferences.getInstance();
      final n = ThemeNotifier(prefs);
      expect(n.state.isMojian, isTrue);
      expect(n.state.mode, ThemeMode.dark);
      expect(n.consumeMojianIntro(), isTrue);
      expect(n.consumeMojianIntro(), isFalse);
      // 下一次启动不再提示
      expect(ThemeNotifier(prefs).consumeMojianIntro(), isFalse);
    });

    test('选过经典的保持经典、不提示；切换风格与强调色会落盘', () async {
      SharedPreferences.setMockInitialValues({
        'onboarding_completed': true,
        'ui_style': 'classic',
      });
      final prefs = await SharedPreferences.getInstance();
      final n = ThemeNotifier(prefs);
      expect(n.state.uiStyle, UiStyle.classic);
      expect(n.consumeMojianIntro(), isFalse);
      await n.setUiStyle(UiStyle.mojian);
      await n.setMojianAccent(MojianAccent.pine);
      expect(prefs.getString('ui_style'), 'mojian');
      expect(prefs.getString('mojian_accent'), 'pine');
    });

    test('壁纸取色:落盘为 wallpaper,重启后保留,预设色留作回落;再选预设即取消', () async {
      SharedPreferences.setMockInitialValues({'mojian_accent': 'indigo'});
      final prefs = await SharedPreferences.getInstance();
      final n = ThemeNotifier(prefs);
      await n.setMojianWallpaperAccent();
      expect(prefs.getString('mojian_accent'), 'wallpaper');
      final again = ThemeNotifier(prefs);
      expect(again.state.mojianWallpaperAccent, isTrue);
      expect(again.state.mojianAccent, MojianAccent.indigo);
      // 系统没给动态色 → 不覆盖预设
      expect(again.state.mojianAccentPair, isNull);
      again.setDynamicPrimary(const Color(0xFF3366CC));
      expect(again.state.mojianAccentPair, isNotNull);
      await again.setMojianAccent(MojianAccent.pine);
      expect(again.state.mojianWallpaperAccent, isFalse);
      expect(prefs.getString('mojian_accent'), 'pine');
    });

    test('墨笺下透明背景不生效，经典下照旧', () {
      const bg = AppBackground(imagePath: '/tmp/bg.png');
      const base = ThemeState(
        mode: ThemeMode.system,
        seedColor: Colors.blue,
        transparentEnabled: true,
        background: bg,
      );
      expect(base.isTransparentActive, isFalse);
      expect(
        base.copyWith(uiStyle: UiStyle.classic).isTransparentActive,
        isTrue,
      );
    });
  });

  group('墨笺配色', () {
    for (final accent in MojianAccent.values) {
      for (final brightness in Brightness.values) {
        test('${accent.name} · ${brightness.name}：文字对比度达标', () {
          final s = MojianTheme.colorScheme(brightness, accent);
          expect(s.brightness, brightness);
          for (final bg in [
            s.surface,
            s.surfaceContainerLow,
            s.surfaceContainer,
            s.surfaceContainerHigh,
          ]) {
            expect(_contrast(s.onSurface, bg), greaterThanOrEqualTo(7));
            expect(
              _contrast(s.onSurfaceVariant, bg),
              greaterThanOrEqualTo(4.5),
            );
            // 链接、选中文字直接用 primary
            expect(_contrast(s.primary, bg), greaterThanOrEqualTo(4.5));
          }
          expect(_contrast(s.onPrimary, s.primary), greaterThanOrEqualTo(4.5));
          expect(
            _contrast(s.onPrimaryContainer, s.primaryContainer),
            greaterThanOrEqualTo(4.5),
          );
          expect(
            _contrast(s.onInverseSurface, s.inverseSurface),
            greaterThanOrEqualTo(7),
          );
          // 输入框、描边按钮的边框需要 3:1
          expect(_contrast(s.outline, s.surface), greaterThanOrEqualTo(3));
          expect(s.surfaceTint, Colors.transparent);
        });

        test('${accent.name} · ${brightness.name}：ThemeData 能装配，标题用宋体', () {
          final scheme = MojianTheme.colorScheme(brightness, accent);
          final theme = MojianTheme.build(
            scheme: scheme,
            accent: accent,
            fontFamily: null,
            pageTransitionsTheme: const PageTransitionsTheme(),
            iconTheme: const IconThemeData(),
            primaryIconTheme: const IconThemeData(),
          );
          expect(theme.colorScheme, scheme);
          expect(theme.scaffoldBackgroundColor, scheme.surface);
          expect(
            theme.textTheme.titleLarge?.fontFamily,
            MojianTokens.serifFamily,
          );
          expect(
            theme.textTheme.headlineSmall?.fontFamily,
            MojianTokens.serifFamily,
          );
          // 正文仍用正文字体
          expect(
            theme.textTheme.bodyMedium?.fontFamily,
            isNot(MojianTokens.serifFamily),
          );
          expect(
            theme.appBarTheme.titleTextStyle?.fontFamily,
            MojianTokens.serifFamily,
          );
          final tokens = theme.extension<MojianTokens>();
          expect(tokens, isNotNull);
          expect(tokens!.accent, accent.of(brightness));
          // 正文引用块/小标题的覆盖样式随墨笺一起注入
          final rs = theme.extension<FluxdoRenderStyle>();
          expect(rs?.quoteBarWidth, 2);
          expect(rs?.quoteBackground, Colors.transparent);
          expect(rs?.headingFontFamily, MojianTokens.serifFamily);
          expect(rs?.quoteFontFamily, MojianTokens.serifFamily);
        });
      }
    }

    test('纯黑:只改深色的纸与表面,文字对比度仍达标;浅色不受影响', () {
      for (final accent in MojianAccent.values) {
        final s = MojianTheme.colorScheme(Brightness.dark, accent, black: true);
        expect(s.surface, const Color(0xFF000000));
        for (final bg in [s.surface, s.surfaceContainer]) {
          expect(_contrast(s.onSurfaceVariant, bg), greaterThanOrEqualTo(4.5));
          expect(_contrast(s.primary, bg), greaterThanOrEqualTo(4.5));
        }
        final theme = MojianTheme.build(
          scheme: s,
          accent: accent,
          fontFamily: null,
          pageTransitionsTheme: const PageTransitionsTheme(),
          iconTheme: const IconThemeData(),
          primaryIconTheme: const IconThemeData(),
        );
        expect(theme.extension<MojianTokens>()!.paper, const Color(0xFF000000));
        expect(
          MojianTheme.colorScheme(Brightness.light, accent, black: true),
          MojianTheme.colorScheme(Brightness.light, accent),
        );
      }
    });

    test('壁纸取色:任意种子色推出的强调色在纸色各层上都 ≥ 4.5:1', () {
      for (final seed in const [
        Color(0xFFFFEB3B), // 亮黄
        Color(0xFF90CAF9), // 浅蓝
        Color(0xFF0D1B4C), // 深海军蓝
        Color(0xFF00E676), // 荧光绿
        Color(0xFF9E9E9E), // 灰
      ]) {
        final (light, dark) = MojianTheme.accentFromSeed(seed);
        for (final b in Brightness.values) {
          for (final black in [false, true]) {
            final s = MojianTheme.colorScheme(
              b,
              MojianAccent.cinnabar,
              black: black,
              accentColor: b == Brightness.light ? light : dark,
            );
            for (final bg in [
              s.surface,
              s.surfaceContainerLow,
              s.surfaceContainer,
              s.surfaceContainerHigh,
            ]) {
              expect(
                _contrast(s.primary, bg),
                greaterThanOrEqualTo(4.5),
                reason: 'seed $seed $b black=$black bg $bg',
              );
            }
            expect(
              _contrast(s.onPrimary, s.primary),
              greaterThanOrEqualTo(4.5),
            );
          }
        }
      }
    });

    test('令牌插值两端取值正确', () {
      final a = MojianTokens.of(Brightness.light, MojianAccent.cinnabar);
      final b = MojianTokens.of(Brightness.dark, MojianAccent.indigo);
      expect(a.lerp(b, 0).paper, a.paper);
      expect(a.lerp(b, 1).accent, b.accent);
      expect(a.lerp(null, 0.5), same(a));
    });
  });

  testWidgets('选择标签:未选中墨色、选中纸色(不能落成看不见的纸色)', (tester) async {
    final theme = MojianTheme.build(
      scheme: MojianTheme.colorScheme(Brightness.light, MojianAccent.cinnabar),
      accent: MojianAccent.cinnabar,
      fontFamily: null,
      pageTransitionsTheme: const PageTransitionsTheme(),
      iconTheme: const IconThemeData(),
      primaryIconTheme: const IconThemeData(),
    );
    final t = theme.extension<MojianTokens>()!;
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
        find.descendant(of: find.text(label), matching: find.byType(RichText)),
      );
      return rich.text.style?.color;
    }

    expect(colorOf('on'), t.paper);
    expect(colorOf('off'), t.ink2);
  });
}
