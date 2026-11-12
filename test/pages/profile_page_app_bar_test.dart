import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/models/user.dart';
import 'package:fluxdo/pages/profile_page.dart';
import 'package:fluxdo/providers/core_providers.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/services/local_notification_service.dart';
import 'package:fluxdo/services/site_context.dart';
import 'package:fluxdo/widgets/layout/site_switch_button.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Guest extends CurrentUserNotifier {
  @override
  User? build() => null;
}

/// 经典主题的口径：Material 3 默认配色，不配 appBarTheme
ThemeData _classic(Brightness brightness) => ThemeData(
  useMaterial3: true,
  colorScheme: ColorScheme.fromSeed(
    seedColor: Colors.blue,
    brightness: brightness,
  ),
);

Future<void> _pumpProfile(
  WidgetTester tester, {
  required Size size,
  Brightness brightness = Brightness.light,
}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  // 响应式断点按 MediaQuery 的窗口宽度判定，要改 view 本身的尺寸
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final container = ProviderContainer(
    retry: (_, _) => null,
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      currentUserProvider.overrideWith(_Guest.new),
    ],
  );
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
  });
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: TranslationProvider(
        child: MaterialApp(
          navigatorKey: navigatorKey,
          theme: _classic(brightness),
          locale: const Locale('zh'),
          supportedLocales: AppLocaleUtils.supportedLocales,
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: const ProfilePage(isActive: true),
        ),
      ),
    ),
  );
  await tester.pump();
}

Color _appBarColor(WidgetTester tester) => tester
    .widget<Material>(
      find
          .descendant(of: find.byType(AppBar), matching: find.byType(Material))
          .first,
    )
    .color!;

void main() {
  testWidgets('手机布局：站点切换在「我的」页顶栏左侧，站名与正文左缘对齐', (tester) async {
    await _pumpProfile(tester, size: const Size(390, 844));

    final switcher = find.descendant(
      of: find.byType(AppBar),
      matching: find.byType(SiteSwitchButton),
    );
    expect(switcher, findsOneWidget);
    expect(
      find.descendant(
        of: switcher,
        matching: find.text(SiteContext.current.name),
      ),
      findsOneWidget,
    );
    // 图标左缘 = 顶栏间距 4 + 按钮内边距 12 = 16，与列表左内边距一致
    expect(
      tester
          .getTopLeft(
            find.descendant(of: switcher, matching: find.byType(Image)),
          )
          .dx,
      16,
    );
    // 站名用小标题字号，不跟顶栏默认的大标题
    final name = tester.renderObject<RenderParagraph>(
      find.descendant(
        of: switcher,
        matching: find.text(SiteContext.current.name),
      ),
    );
    expect(name.text.style!.fontSize, 14);
  });

  for (final brightness in Brightness.values) {
    testWidgets('经典主题 $brightness：内容滚到顶栏下面时顶栏不变色', (tester) async {
      // 矮屏让游客态的短列表也滚得动
      await _pumpProfile(
        tester,
        size: const Size(390, 420),
        brightness: brightness,
      );
      final scheme = Theme.of(tester.element(find.byType(AppBar))).colorScheme;
      expect(_appBarColor(tester), scheme.surface);

      await tester.drag(find.byType(ListView), const Offset(0, -200));
      await tester.pumpAndSettle();

      expect(
        tester
            .state<ScrollableState>(find.byType(Scrollable).first)
            .position
            .pixels,
        greaterThan(0),
      );
      // Material 3 默认会换成 surfaceContainer（浅色下的灰带）
      expect(_appBarColor(tester), scheme.surface);
      expect(_appBarColor(tester), isNot(scheme.surfaceContainer));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('宽屏（有侧栏）时顶栏不放站点切换', (tester) async {
    await _pumpProfile(tester, size: const Size(1280, 800));

    expect(
      find.descendant(
        of: find.byType(AppBar),
        matching: find.byType(SiteSwitchButton),
      ),
      findsNothing,
    );
  });
}
