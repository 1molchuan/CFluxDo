import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/services/custom_font_service.dart';
import 'package:fluxdo/services/fonts/system_font_service.dart';
import 'package:fluxdo/settings/definitions/appearance_defs.dart';
import 'package:fluxdo/settings/settings_model.dart';

/// 临时字体文件：用同步 IO 准备（testWidgets 的 fake async 里真实异步 IO
/// 不会推进），文件内容不需要是真字体，界面只看它存不存在。
late Directory _tempDir;
late File _fontFile;

/// 只挂载外观页「字体」分组的自定义模型，不拉起整页依赖。
Future<SharedPreferences> _pumpFontSection(
  WidgetTester tester, {
  required Map<String, Object> prefsSeed,
}) async {
  SharedPreferences.setMockInitialValues(prefsSeed);
  final prefs = await SharedPreferences.getInstance();

  await tester.pumpWidget(
    ProviderScope(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      child: TranslationProvider(
        child: MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocaleUtils.supportedLocales,
          home: Consumer(
            builder: (context, ref, _) {
              final group = buildAppearanceGroups(
                context,
              ).firstWhere((g) => g.title == context.l10n.appearance_font);
              final model = group.items.single as CustomModel;
              return Scaffold(body: model.builder(context, ref));
            },
          ),
        ),
      ),
    ),
  );
  return prefs;
}

/// 当前选中的字体（RadioGroup 的 groupValue 即状态快照）。
AppFontFamily _selected(WidgetTester tester) => tester
    .widget<RadioGroup<AppFontFamily>>(find.byType(RadioGroup<AppFontFamily>))
    .groupValue!;

void main() {
  setUpAll(() {
    _tempDir = Directory.systemTemp.createTempSync('fluxdo_font_ui');
    _fontFile = File('${_tempDir.path}/custom_font_ui.ttf')
      ..writeAsBytesSync([0, 1, 2]);
  });

  tearDownAll(() {
    if (_tempDir.existsSync()) {
      _tempDir.deleteSync(recursive: true);
    }
  });

  testWidgets('字体分组列出系统 / MiSans / 系统字体 / 自定义四项，未选时给提示', (tester) async {
    await _pumpFontSection(tester, prefsSeed: {});

    expect(find.text('系统默认'), findsOneWidget);
    expect(find.text('MiSans'), findsOneWidget);
    expect(find.text('系统字体'), findsOneWidget);
    expect(find.text('自定义字体'), findsOneWidget);
    expect(find.text('支持 ttf / otf 字体文件'), findsOneWidget);
    expect(find.text('从系统已安装字体中选择'), findsOneWidget);
    // 还没选过字体时不出现文件行 / 已选行
    expect(find.text('移除'), findsNothing);
    expect(find.text('更换'), findsNothing);
    expect(_selected(tester), AppFontFamily.system);

    await tester.tap(find.text('MiSans'));
    await tester.pump();

    expect(_selected(tester), AppFontFamily.miSans);
    expect(find.text('支持 ttf / otf 字体文件'), findsOneWidget);
  });

  testWidgets('已选系统字体：显示所选名字，回切不重复拉起选择面板', (tester) async {
    final prefs = await _pumpFontSection(
      tester,
      prefsSeed: {
        'font_family': 'miSans',
        SystemFontService.familyPrefKey: 'Microsoft YaHei',
        SystemFontService.namePrefKey: '微软雅黑',
      },
    );

    expect(find.text('微软雅黑'), findsOneWidget);
    expect(find.text('更换'), findsOneWidget);
    // 已经选过：不再显示选择提示
    expect(find.text('从系统已安装字体中选择'), findsNothing);

    await tester.tap(find.text('系统字体'));
    await tester.pump();

    expect(_selected(tester), AppFontFamily.installed);
    expect(prefs.getString('font_family'), 'installed');
  });

  testWidgets('已有字体文件：显示文件名，可在自选与内置字体间来回切换', (tester) async {
    final prefs = await _pumpFontSection(
      tester,
      prefsSeed: {
        'font_family': 'custom',
        CustomFontService.pathPrefKey: _fontFile.path,
        CustomFontService.namePrefKey: 'HarmonyOS Sans.ttf',
      },
    );

    expect(_selected(tester), AppFontFamily.custom);
    expect(find.text('HarmonyOS Sans.ttf'), findsOneWidget);
    // 有文件时不再显示选择提示
    expect(find.text('支持 ttf / otf 字体文件'), findsNothing);

    await tester.tap(find.text('系统默认'));
    await tester.pump();
    expect(_selected(tester), AppFontFamily.system);
    expect(prefs.getString('font_family'), 'system');

    await tester.tap(find.text('自定义字体'));
    await tester.pump();
    // 文件还在：直接切回自选字体，不重复拉起文件选择器
    expect(_selected(tester), AppFontFamily.custom);
    expect(prefs.getString('font_family'), 'custom');
  });

  testWidgets('移除自选字体：回退系统默认、清掉记录、收起文件行', (tester) async {
    final prefs = await _pumpFontSection(
      tester,
      prefsSeed: {
        'font_family': 'custom',
        CustomFontService.pathPrefKey: _fontFile.path,
        CustomFontService.namePrefKey: 'HarmonyOS Sans.ttf',
      },
    );

    await tester.tap(find.text('移除'));
    await tester.pump();

    expect(_selected(tester), AppFontFamily.system);
    expect(find.text('HarmonyOS Sans.ttf'), findsNothing);
    expect(find.text('移除'), findsNothing);
    expect(find.text('支持 ttf / otf 字体文件'), findsOneWidget);
    expect(prefs.getString(CustomFontService.pathPrefKey), isNull);
    expect(prefs.getString(CustomFontService.namePrefKey), isNull);
  });

  testWidgets('字体文件丢失时给出提示并保留更换入口', (tester) async {
    await _pumpFontSection(
      tester,
      prefsSeed: {
        'font_family': 'custom',
        CustomFontService.pathPrefKey: '${_tempDir.path}/gone.ttf',
        CustomFontService.namePrefKey: 'Gone.ttf',
      },
    );

    expect(find.text('字体文件已丢失'), findsOneWidget);
    expect(find.text('更换'), findsOneWidget);
    expect(find.text('移除'), findsOneWidget);
  });
}
