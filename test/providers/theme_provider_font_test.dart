import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/services/custom_font_service.dart';
import 'package:fluxdo/services/fonts/system_font_service.dart';

Future<ProviderContainer> _createContainer(SharedPreferences prefs) async {
  final container = ProviderContainer(
    overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  test('选中自选字体：状态与 prefs 同步，重启后仍在', () async {
    final tempDir = await Directory.systemTemp.createTemp('fluxdo_font_test');
    addTearDown(() => tempDir.delete(recursive: true));
    final fontFile = File('${tempDir.path}/custom_font_1.ttf')
      ..writeAsBytesSync([0, 1, 2]);

    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final container = await _createContainer(prefs);

    expect(container.read(themeProvider).fontFamily, AppFontFamily.system);
    expect(container.read(themeProvider).fontFamilyName, isNull);

    await container
        .read(themeProvider.notifier)
        .setCustomFont(path: fontFile.path, name: 'HarmonyOS Sans.ttf');

    final state = container.read(themeProvider);
    expect(state.fontFamily, AppFontFamily.custom);
    expect(state.customFontName, 'HarmonyOS Sans.ttf');
    expect(
      state.fontFamilyName,
      CustomFontService.familyNameFor(fontFile.path),
    );
    expect(prefs.getString(CustomFontService.pathPrefKey), fontFile.path);
    expect(
      prefs.getString(CustomFontService.namePrefKey),
      'HarmonyOS Sans.ttf',
    );

    // 重建 notifier（等价于重启）应恢复自选字体
    final reloaded = await _createContainer(prefs);
    final reloadedState = reloaded.read(themeProvider);
    expect(reloadedState.fontFamily, AppFontFamily.custom);
    expect(reloadedState.customFontPath, fontFile.path);
    expect(reloadedState.customFontName, 'HarmonyOS Sans.ttf');
  });

  test('移除自选字体：回退系统默认并删掉字体文件', () async {
    final tempDir = await Directory.systemTemp.createTemp('fluxdo_font_test');
    addTearDown(() => tempDir.delete(recursive: true));
    final fontFile = File('${tempDir.path}/custom_font_2.ttf')
      ..writeAsBytesSync([0, 1, 2]);

    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final container = await _createContainer(prefs);
    final notifier = container.read(themeProvider.notifier);

    await notifier.setCustomFont(path: fontFile.path, name: 'My Font.otf');
    await notifier.removeCustomFont();

    final state = container.read(themeProvider);
    expect(state.fontFamily, AppFontFamily.system);
    expect(state.fontFamilyName, isNull);
    expect(state.customFontPath, isNull);
    expect(state.customFontName, isNull);
    expect(prefs.getString(CustomFontService.pathPrefKey), isNull);
    expect(prefs.getString(CustomFontService.namePrefKey), isNull);
    expect(fontFile.existsSync(), isFalse);
  });

  test('选中系统字体：状态与 prefs 同步，重启后仍在', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final container = await _createContainer(prefs);

    await container
        .read(themeProvider.notifier)
        .setInstalledFont(family: 'Microsoft YaHei', name: '微软雅黑');

    final state = container.read(themeProvider);
    expect(state.fontFamily, AppFontFamily.installed);
    expect(state.fontFamilyName, 'Microsoft YaHei');
    expect(state.installedFontName, '微软雅黑');
    expect(prefs.getString(SystemFontService.familyPrefKey), 'Microsoft YaHei');
    expect(prefs.getString(SystemFontService.namePrefKey), '微软雅黑');

    // 重建 notifier（等价于重启）应恢复所选系统字体
    final reloaded = await _createContainer(prefs);
    final reloadedState = reloaded.read(themeProvider);
    expect(reloadedState.fontFamily, AppFontFamily.installed);
    expect(reloadedState.fontFamilyName, 'Microsoft YaHei');
    expect(reloadedState.installedFontName, '微软雅黑');
  });

  test('选了系统字体但 family 记录缺失：回落系统默认，不出现空选中', () async {
    SharedPreferences.setMockInitialValues({'font_family': 'installed'});
    final prefs = await SharedPreferences.getInstance();
    final container = await _createContainer(prefs);

    final state = container.read(themeProvider);
    expect(state.fontFamily, AppFontFamily.system);
    expect(state.fontFamilyName, isNull);
  });

  test('未导入文件时选中 custom 不影响渲染 family', () async {
    SharedPreferences.setMockInitialValues({'font_family': 'custom'});
    final prefs = await SharedPreferences.getInstance();
    final container = await _createContainer(prefs);

    final state = container.read(themeProvider);
    expect(state.fontFamily, AppFontFamily.custom);
    expect(state.customFontPath, isNull);
    expect(state.fontFamilyName, isNull);

    // 切回内置字体只改选择本身
    await container
        .read(themeProvider.notifier)
        .setFontFamily(AppFontFamily.miSans);
    expect(container.read(themeProvider).fontFamilyName, 'MiSans');
  });

  test('移除自选字体时当前用的是别的字体，选择保持不变', () async {
    final tempDir = Directory.systemTemp.createTempSync('fluxdo_font_test');
    addTearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });
    final fontFile = File('${tempDir.path}/custom_font_3.ttf')
      ..writeAsBytesSync([0, 1, 2]);

    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final container = await _createContainer(prefs);
    final notifier = container.read(themeProvider.notifier);

    await notifier.setCustomFont(path: fontFile.path, name: 'My Font.ttf');
    await notifier.setFontFamily(AppFontFamily.miSans);
    await notifier.removeCustomFont();

    final state = container.read(themeProvider);
    expect(state.fontFamily, AppFontFamily.miSans);
    expect(state.customFontPath, isNull);
    expect(prefs.getString('font_family'), 'miSans');
    expect(fontFile.existsSync(), isFalse);
  });
}
