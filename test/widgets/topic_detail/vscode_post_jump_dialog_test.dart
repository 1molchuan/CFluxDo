import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/models/shortcut_binding.dart';
import 'package:fluxdo/providers/shortcut_provider.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/theme/vscode_theme.dart';
import 'package:fluxdo/utils/dialog_utils.dart';
import 'package:fluxdo/utils/platform_utils.dart';
import 'package:fluxdo/widgets/keyboard_shortcut_handler.dart';
import 'package:fluxdo/widgets/topic_detail/vscode_post_jump_dialog.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _targetKey = ValueKey('vscode-post-jump-target');
const _panelKey = ValueKey('vscode-post-jump-panel');

class _JumpResult {
  int? target;
  int closeCount = 0;
}

Future<_JumpResult> _openDialog(
  WidgetTester tester, {
  int currentPostNumber = 12,
  int maxPostNumber = 100,
  double textScale = 1,
  double keyboardInset = 0,
}) async {
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  final navigatorKey = GlobalKey<NavigatorState>();
  final result = _JumpResult();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [sharedPreferencesProvider.overrideWithValue(preferences)],
      child: TranslationProvider(
        child: KeyboardShortcutHandler(
          navigatorKey: navigatorKey,
          child: MaterialApp(
            navigatorKey: navigatorKey,
            locale: const Locale('zh'),
            supportedLocales: AppLocaleUtils.supportedLocales,
            localizationsDelegates: const [
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            theme: ThemeData(
              colorScheme: VscodeTheme.colorScheme(Brightness.light),
              extensions: [VscodeTokens.of(Brightness.light)],
            ),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: TextScaler.linear(textScale),
                viewInsets: EdgeInsets.only(bottom: keyboardInset),
              ),
              child: child!,
            ),
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () async {
                    result.target = await showAppDialog<int>(
                      context: context,
                      blur: false,
                      barrierColor: Colors.transparent,
                      shortcutSurface: const ShortcutSurfaceConfig(
                        id: ShortcutSurfaceIds.topicJumpToPost,
                        triggerAction: ShortcutAction.jumpToPost,
                        repeatBehavior: ShortcutSurfaceRepeatBehavior.toggle,
                      ),
                      builder: (_) => VscodePostJumpDialog(
                        currentPostNumber: currentPostNumber,
                        maxPostNumber: maxPostNumber,
                      ),
                    );
                    result.closeCount++;
                  },
                  child: const Text('打开楼层跳转'),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开楼层跳转'));
  await tester.pumpAndSettle();
  return result;
}

void main() {
  setUp(() => PlatformUtils.debugDesktopOverride = true);
  tearDown(() => PlatformUtils.debugDesktopOverride = null);

  testWidgets('拖动到末楼同步输入和候选，松手不跳转，Enter 才确认', (tester) async {
    final result = await _openDialog(
      tester,
      currentPostNumber: 12,
      maxPostNumber: 100,
    );
    final slider = find.byType(Slider);
    final gesture = await tester.startGesture(tester.getCenter(slider));
    await gesture.moveBy(const Offset(2000, 0));
    await tester.pump();
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.text, '100');
    expect(
      find.text(tester.element(slider).l10n.topic_jumpTarget(100)),
      findsOneWidget,
    );
    expect(result.closeCount, 0);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(result.closeCount, 0);
    expect(field.focusNode!.hasFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(result.target, 100);
    expect(result.closeCount, 1);
  });

  testWidgets('输入同步滑块位置，无效输入也能通过拖动回到首楼并确认', (tester) async {
    final result = await _openDialog(tester, maxPostNumber: 100);
    await tester.enterText(find.byType(TextField), ':75');
    await tester.pump();
    expect(tester.widget<Slider>(find.byType(Slider)).value, 75);
    await tester.enterText(find.byType(TextField), 'abc');
    await tester.pump();
    expect(find.byKey(_targetKey), findsNothing);
    await tester.drag(find.byType(Slider), const Offset(-2000, 0));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '1',
    );
    expect(result.closeCount, 0);
    await tester.tap(find.byKey(_targetKey));
    await tester.pumpAndSettle();
    expect(result.target, 1);
  });

  testWidgets('只有一楼时拖动条不可调整，但仍可确认首楼', (tester) async {
    final result = await _openDialog(
      tester,
      currentPostNumber: 1,
      maxPostNumber: 1,
    );
    await tester.drag(find.byType(Slider), const Offset(300, 0));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '1',
    );
    expect(result.closeCount, 0);
    await tester.tap(find.byKey(_targetKey));
    await tester.pumpAndSettle();
    expect(result.target, 1);
    expect(tester.takeException(), isNull);
  });
  testWidgets('打开时全选当前楼层，输入面板在顶部居中且不抢整屏', (tester) async {
    await _openDialog(tester, currentPostNumber: 37, maxPostNumber: 80);
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.focusNode!.hasFocus, isTrue);
    expect(field.controller!.text, '37');
    expect(
      field.controller!.selection,
      const TextSelection(baseOffset: 0, extentOffset: 2),
    );
    final panel = tester.getRect(find.byKey(_panelKey));
    expect(panel.width, 520);
    expect(panel.top, 12);
    expect(panel.center.dx, tester.getSize(find.byType(Scaffold)).width / 2);
  });

  testWidgets('纯数字按 Enter 返回目标，关闭后销毁输入状态', (tester) async {
    final result = await _openDialog(tester);
    final controller = tester
        .widget<TextField>(find.byType(TextField))
        .controller!;
    await tester.enterText(find.byType(TextField), '42');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(result.target, 42);
    expect(result.closeCount, 1);
    expect(find.byType(VscodePostJumpDialog), findsNothing);
    expect(() => controller.addListener(() {}), throwsFlutterError);
    expect(tester.takeException(), isNull);
  });

  testWidgets('单个冒号前缀候选可以点击，点击与 Enter 返回相同结果', (tester) async {
    final result = await _openDialog(tester);
    await tester.enterText(find.byType(TextField), ':58');
    await tester.pump();
    final l10n = tester.element(find.byType(TextField)).l10n;
    expect(find.text(l10n.topic_jumpTarget(58)), findsOneWidget);
    await tester.tap(find.byKey(_targetKey));
    await tester.pumpAndSettle();
    expect(result.target, 58);
    expect(result.closeCount, 1);
  });

  testWidgets('无效和非正数没有候选，按 Enter 不关闭也不跳转', (tester) async {
    final result = await _openDialog(tester);
    for (final input in [
      '',
      '0',
      ':0',
      '-2',
      '+2',
      '1.5',
      'abc',
      '::5',
      ': 5',
      '99999999999999999999999999999',
    ]) {
      await tester.enterText(find.byType(TextField), input);
      await tester.pump();
      final l10n = tester.element(find.byType(TextField)).l10n;
      expect(find.byKey(_targetKey), findsNothing, reason: input);
      expect(find.text(l10n.topic_jumpInvalid), findsOneWidget, reason: input);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(result.closeCount, 0, reason: input);
      expect(result.target, isNull, reason: input);
      expect(find.byType(VscodePostJumpDialog), findsOneWidget, reason: input);
    }
  });

  testWidgets('越界数字展示截断后的真实目标，Enter 使用同一目标', (tester) async {
    final result = await _openDialog(tester, maxPostNumber: 75);
    await tester.enterText(find.byType(TextField), ':999');
    await tester.pump();
    final l10n = tester.element(find.byType(TextField)).l10n;
    expect(find.text(l10n.topic_jumpTarget(75)), findsOneWidget);
    expect(find.text(l10n.topic_jumpTarget(999)), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(result.target, 75);
  });

  testWidgets('聚焦输入时 Esc 经原有快捷键路由关闭且不提交', (tester) async {
    final result = await _openDialog(tester);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(VscodePostJumpDialog)),
      listen: false,
    );
    expect(
      container
          .read(shortcutSurfaceRegistryProvider)
          .registrations
          .values
          .map((surface) => surface.id),
      contains(ShortcutSurfaceIds.topicJumpToPost),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await tester.pumpAndSettle();
    expect(result.target, isNull);
    expect(result.closeCount, 1);
    expect(find.byType(VscodePostJumpDialog), findsNothing);
    expect(
      container.read(shortcutSurfaceRegistryProvider).registrations,
      isEmpty,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('退场过程中再次点击不会重复提交或关闭背后的页面', (tester) async {
    final result = await _openDialog(tester);
    await tester.enterText(find.byType(TextField), '24');
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.tap(find.byKey(_targetKey), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(result.target, 24);
    expect(result.closeCount, 1);
    expect(find.text('打开楼层跳转'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('点击面板外部可取消快速跳转', (tester) async {
    final result = await _openDialog(tester);
    await tester.tapAt(const Offset(5, 500));
    await tester.pumpAndSettle();
    expect(result.target, isNull);
    expect(result.closeCount, 1);
    expect(find.byType(VscodePostJumpDialog), findsNothing);
  });

  testWidgets('窄屏大字与键盘同时出现仍保持屏内并可点击目标', (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final result = await _openDialog(
      tester,
      maxPostNumber: 9999,
      textScale: 2.4,
      keyboardInset: 220,
    );
    final panel = tester.getRect(find.byKey(_panelKey));
    expect(panel.width, lessThanOrEqualTo(296));
    expect(panel.left, greaterThanOrEqualTo(12));
    expect(panel.top, 12);
    expect(panel.bottom, lessThanOrEqualTo(408));
    expect(tester.takeException(), isNull);
    await tester.enterText(find.byType(TextField), ':789');
    await tester.pump();
    await tester.ensureVisible(find.byKey(_targetKey));
    await tester.tap(find.byKey(_targetKey));
    await tester.pumpAndSettle();
    expect(result.target, 789);
    expect(tester.takeException(), isNull);
  });
}
