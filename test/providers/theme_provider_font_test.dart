import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/services/custom_font_service.dart';
import 'package:fluxdo/services/fonts/system_font_service.dart';
import 'package:fluxdo/theme/mojian_theme.dart';

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

  test('删掉导入的字体：回退系统默认、清掉记录并删掉字体文件', () async {
    final tempDir = await Directory.systemTemp.createTemp('fluxdo_font_test');
    addTearDown(() => tempDir.delete(recursive: true));
    final fontFile = File('${tempDir.path}/custom_font_2.ttf')
      ..writeAsBytesSync([0, 1, 2]);

    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final container = await _createContainer(prefs);
    final notifier = container.read(themeProvider.notifier);

    await notifier.importFont(path: fontFile.path, name: 'My Font.otf');
    expect(container.read(themeProvider).importedFontPath, fontFile.path);
    await notifier.removeImportedFont();

    final state = container.read(themeProvider);
    expect(state.fontFamily, AppFontFamily.system);
    expect(state.fontFamilyName, isNull);
    expect(state.customFontPath, isNull);
    expect(state.importedFontPath, isNull);
    expect(state.importedFontName, isNull);
    expect(prefs.getString(CustomFontService.pathPrefKey), isNull);
    expect(prefs.getString('imported_font_path'), isNull);
    expect(fontFile.existsSync(), isFalse);
  });

  test('导入的字体换成推荐字体后仍留在列表里，重启后也在', () async {
    final tempDir = await Directory.systemTemp.createTemp('fluxdo_font_test');
    addTearDown(() => tempDir.delete(recursive: true));
    final imported = File('${tempDir.path}/custom_font_4.ttf')
      ..writeAsBytesSync([0, 1, 2]);
    Directory('${tempDir.path}/recommended_fonts').createSync();
    final recommended = File('${tempDir.path}/recommended_fonts/lxgw.ttf')
      ..writeAsBytesSync([3, 4, 5]);

    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final container = await _createContainer(prefs);
    final notifier = container.read(themeProvider.notifier);

    await notifier.importFont(path: imported.path, name: 'Mine.ttf');
    await notifier.setCustomFont(path: recommended.path, name: '霞鹜文楷');

    var state = container.read(themeProvider);
    expect(state.customFontPath, recommended.path);
    expect(state.importedFontPath, imported.path);
    expect(state.importedFontName, 'Mine.ttf');

    // 推荐字体被删：只清当前记录、回退系统默认，导入的那份不动
    await notifier.stopUsingFontFile(recommended.path);
    state = container.read(themeProvider);
    expect(state.fontFamily, AppFontFamily.system);
    expect(state.customFontPath, isNull);
    expect(state.importedFontPath, imported.path);
    expect(imported.existsSync(), isTrue);

    final reloaded = (await _createContainer(prefs)).read(themeProvider);
    expect(reloaded.importedFontPath, imported.path);
    expect(reloaded.importedFontName, 'Mine.ttf');
  });

  test('老版本只记了当前字体文件：导入的字体从那里认领，推荐字体不认领', () async {
    SharedPreferences.setMockInitialValues({
      'font_family': 'custom',
      CustomFontService.pathPrefKey: '/data/custom_fonts/custom_font_1.ttf',
      CustomFontService.namePrefKey: 'Old.ttf',
    });
    var state = (await _createContainer(
      await SharedPreferences.getInstance(),
    )).read(themeProvider);
    expect(state.importedFontPath, '/data/custom_fonts/custom_font_1.ttf');
    expect(state.importedFontName, 'Old.ttf');

    SharedPreferences.setMockInitialValues({
      'font_family': 'custom',
      CustomFontService.pathPrefKey:
          r'C:\Users\me\AppData\recommended_fonts/lxgw.ttf',
      CustomFontService.namePrefKey: '霞鹜文楷',
    });
    state = (await _createContainer(
      await SharedPreferences.getInstance(),
    )).read(themeProvider);
    expect(state.importedFontPath, isNull);
  });

  test('墨笺标题：默认按所选字体决定，手动设置后以设置为准', () async {
    final tempDir = await Directory.systemTemp.createTemp('fluxdo_font_test');
    addTearDown(() => tempDir.delete(recursive: true));
    final fontFile = File('${tempDir.path}/custom_font_5.ttf')
      ..writeAsBytesSync([0, 1, 2]);

    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final container = await _createContainer(prefs);
    final notifier = container.read(themeProvider.notifier);

    // 系统默认 / MiSans：宋体标题（null = 宋体）
    expect(container.read(themeProvider).serifTitles, isTrue);
    expect(container.read(themeProvider).titleFontFamilyName, isNull);

    // 自己选的字体：标题跟着换
    await notifier.setCustomFont(path: fontFile.path, name: 'A.ttf');
    expect(container.read(themeProvider).serifTitles, isFalse);
    expect(
      container.read(themeProvider).titleFontFamilyName,
      CustomFontService.familyNameFor(fontFile.path),
    );

    // 关掉宋体标题 + 系统默认：标题用平台正文字体名，不能是 null（那是宋体）
    await notifier.setFontFamily(AppFontFamily.system);
    await notifier.setMojianSerifTitles(false);
    var state = container.read(themeProvider);
    expect(state.serifTitles, isFalse);
    expect(state.titleFontFamilyName, MojianTheme.platformBodyFamily);
    expect(state.titleFontFamilyName, isNotNull);

    // 打开后选了自己的字体也保持宋体
    await notifier.setMojianSerifTitles(true);
    await notifier.setFontFamily(AppFontFamily.custom);
    state = container.read(themeProvider);
    expect(state.serifTitles, isTrue);
    expect(state.titleFontFamilyName, isNull);

    final reloaded = (await _createContainer(prefs)).read(themeProvider);
    expect(reloaded.mojianSerifTitles, isTrue);
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

  test('删掉导入的字体时当前用的是别的字体，选择保持不变', () async {
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

    await notifier.importFont(path: fontFile.path, name: 'My Font.ttf');
    await notifier.setFontFamily(AppFontFamily.miSans);
    await notifier.removeImportedFont();

    final state = container.read(themeProvider);
    expect(state.fontFamily, AppFontFamily.miSans);
    expect(state.customFontPath, isNull);
    expect(state.importedFontPath, isNull);
    expect(prefs.getString('font_family'), 'miSans');
    expect(fontFile.existsSync(), isFalse);
  });
}
