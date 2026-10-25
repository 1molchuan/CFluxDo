import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/pages/topics_page.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/widgets/layout/adaptive_navigation.dart';
import 'package:fluxdo/widgets/layout/adaptive_scaffold.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('手机端 barVisibility 为 0 时将底部导航栏平移出屏', (tester) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.binding.setSurfaceSize(const Size(390, 844));

    SharedPreferences.setMockInitialValues({'pref_hide_bar_on_scroll': true});
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
    );
    addTearDown(container.dispose);
    container.read(barVisibilityProvider.notifier).state = 0;

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: TranslationProvider(
          child: MaterialApp(
            home: MediaQuery(
              data: const MediaQueryData(size: Size(390, 844)),
              child: AdaptiveScaffold(
                selectedIndex: 1,
                onDestinationSelected: (_) {},
                destinations: const [
                  AdaptiveDestination(
                    id: 'home',
                    icon: Icon(Icons.home_outlined),
                    selectedIcon: Icon(Icons.home),
                    label: '首页',
                  ),
                  AdaptiveDestination(
                    id: 'bookmarks',
                    icon: Icon(Icons.bookmark_outline_rounded),
                    selectedIcon: Icon(Icons.bookmark_rounded),
                    label: '书签',
                  ),
                ],
                body: const SizedBox.expand(child: Text('body')),
              ),
            ),
          ),
        ),
      ),
    );

    // 滚动平移层的 child 是投影开合层(AnimatedSlide),再往里才是底栏
    // 本体;AnimatedSlide 自身也由 FractionalTranslation 实现,不能只按
    // 类型找。
    final bottomNavTranslation = find.byWidgetPredicate(
      (widget) =>
          widget is FractionalTranslation && widget.child is AnimatedSlide,
    );

    expect(find.byType(NavigationBar), findsOneWidget);
    expect(bottomNavTranslation, findsOneWidget);
    expect(
      tester.widget<FractionalTranslation>(bottomNavTranslation).translation,
      const Offset(0, 1),
    );

    container.read(barVisibilityProvider.notifier).state = 1;
    await tester.pumpAndSettle();

    expect(find.byType(NavigationBar), findsOneWidget);
    expect(
      tester.widget<FractionalTranslation>(bottomNavTranslation).translation,
      Offset.zero,
    );
  });

  testWidgets('横屏二级平行视界隐藏全局侧栏', (tester) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.binding.setSurfaceSize(const Size(1400, 900));

    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: TranslationProvider(
          child: MaterialApp(
            home: MediaQuery(
              data: const MediaQueryData(size: Size(1400, 900)),
              child: AdaptiveScaffold(
                selectedIndex: 0,
                onDestinationSelected: (_) {},
                hideNavigationRail: true,
                destinations: const [
                  AdaptiveDestination(
                    id: 'home',
                    icon: Icon(Icons.home_outlined),
                    selectedIcon: Icon(Icons.home),
                    label: '首页',
                  ),
                  AdaptiveDestination(
                    id: 'messages',
                    icon: Icon(Icons.mail_outline),
                    selectedIcon: Icon(Icons.mail),
                    label: '私信',
                  ),
                ],
                body: const SizedBox.expand(child: Text('平行视界内容')),
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.byType(AdaptiveNavigationRail), findsNothing);
    expect(find.byType(NavigationBar), findsNothing);
    expect(find.text('平行视界内容'), findsOneWidget);
  });

  testWidgets('手机端 body 保留 Scaffold 注入的底栏 inset（extendBody），顶部 inset 由站点条吃掉', (
    tester,
  ) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.binding.setSurfaceSize(const Size(390, 844));

    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
    );
    addTearDown(container.dispose);

    EdgeInsets? bodyPadding;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: TranslationProvider(
          child: MaterialApp(
            home: MediaQuery(
              data: const MediaQueryData(
                size: Size(390, 844),
                padding: EdgeInsets.only(top: 44, bottom: 20),
                viewPadding: EdgeInsets.only(top: 44, bottom: 20),
              ),
              child: AdaptiveScaffold(
                selectedIndex: 0,
                onDestinationSelected: (_) {},
                destinations: const [
                  AdaptiveDestination(
                    id: 'home',
                    icon: Icon(Icons.home_outlined),
                    selectedIcon: Icon(Icons.home),
                    label: '首页',
                  ),
                  AdaptiveDestination(
                    id: 'bookmarks',
                    icon: Icon(Icons.bookmark_outline_rounded),
                    selectedIcon: Icon(Icons.bookmark_rounded),
                    label: '书签',
                  ),
                ],
                body: Builder(
                  builder: (context) {
                    bodyPadding = MediaQuery.paddingOf(context);
                    return const SizedBox.expand(child: Text('body'));
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final navHeight = tester.getSize(find.byType(NavigationBar)).height;
    expect(navHeight, greaterThan(0));
    // 底栏在 body 后面（extendBody），FAB / 列表尾部靠这份 inset 让位；
    // 1.2.2-beta 用外层 context 重建 MediaQuery 把它丢成 0，FAB 整个被底栏盖住
    expect(bodyPadding!.bottom, navHeight);
    // 状态栏 inset 由站点切换条上方的 SafeArea 消费，body 不再重复让位
    expect(bodyPadding!.top, 0);
  });
}
