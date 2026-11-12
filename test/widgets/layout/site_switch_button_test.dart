import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/config/forum_site.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/services/site_context.dart';
import 'package:fluxdo/theme/mojian_theme.dart';
import 'package:fluxdo/widgets/layout/site_switch_button.dart';

Future<void> _pump(WidgetTester tester, Widget child, {ThemeData? theme}) {
  return tester.pumpWidget(
    TranslationProvider(
      child: MaterialApp(
        theme: theme,
        locale: const Locale('zh'),
        home: Scaffold(
          body: Align(alignment: Alignment.topRight, child: child),
        ),
      ),
    ),
  );
}

void main() {
  final capsule = find.byKey(const ValueKey('site-switch-capsule'));

  testWidgets('胶囊形态：只有图标和箭头，32 高，不显示站名', (tester) async {
    await _pump(tester, const SiteSwitchButton.capsule());

    expect(capsule, findsOneWidget);
    expect(find.text(SiteContext.current.name), findsNothing);
    expect(
      find.descendant(of: capsule, matching: find.byIcon(Icons.expand_more)),
      findsOneWidget,
    );
    final size = tester.getSize(capsule);
    expect(size.height, 32);
    // 比原先的点数药丸窄得多，给首页标题留地方
    expect(size.width, lessThan(60));
    expect(
      tester.widget<Material>(capsule).shape,
      isA<RoundedRectangleBorder>().having(
        (s) => s.borderRadius,
        'borderRadius',
        BorderRadius.circular(16),
      ),
    );
  });

  testWidgets('胶囊点开是两个站点的菜单，当前站点打勾', (tester) async {
    await _pump(tester, const SiteSwitchButton.capsule());

    await tester.tap(capsule);
    await tester.pumpAndSettle();

    for (final site in ForumSite.values) {
      expect(find.text(site.name), findsOneWidget);
    }
    expect(find.byIcon(Icons.check), findsOneWidget);
    final currentItem = find.ancestor(
      of: find.text(SiteContext.current.name),
      matching: find.byType(PopupMenuItem<ForumSite>),
    );
    expect(
      find.descendant(of: currentItem, matching: find.byIcon(Icons.check)),
      findsOneWidget,
    );
    // 菜单在胶囊下方展开，不盖住工具栏
    expect(
      tester.getTopLeft(find.byType(PopupMenuItem<ForumSite>).first).dy,
      greaterThanOrEqualTo(tester.getBottomLeft(capsule).dy),
    );

    // 选当前站点不触发切换，菜单收起
    await tester.tap(find.text(SiteContext.current.name));
    await tester.pumpAndSettle();
    expect(find.byType(PopupMenuItem<ForumSite>), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('墨笺下胶囊是纸色细线框小圆角', (tester) async {
    final theme = MojianTheme.build(
      scheme: MojianTheme.colorScheme(Brightness.light, MojianAccent.cinnabar),
      accent: MojianAccent.cinnabar,
      fontFamily: null,
      pageTransitionsTheme: const PageTransitionsTheme(),
      iconTheme: const IconThemeData(),
      primaryIconTheme: const IconThemeData(),
    );
    await _pump(tester, const SiteSwitchButton.capsule(), theme: theme);

    final mj = theme.extension<MojianTokens>()!;
    final material = tester.widget<Material>(capsule);
    expect(material.color, mj.paper2);
    final shape = material.shape! as RoundedRectangleBorder;
    expect(shape.borderRadius, BorderRadius.circular(4));
    expect(shape.side.color, mj.ruleStrong);
  });

  testWidgets('带站名的形态（「我的」页顶栏、宽侧栏）显示站名与箭头', (tester) async {
    await _pump(tester, const SiteSwitchButton(extended: true));

    expect(find.text(SiteContext.current.name), findsOneWidget);
    expect(find.byIcon(Icons.expand_more), findsOneWidget);
    expect(capsule, findsNothing);
  });
}
