import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/models/topic.dart';
import 'package:fluxdo/providers/draft_store_provider.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/services/discourse/discourse_service.dart';
import 'package:fluxdo/services/local_notification_service.dart';
import 'package:fluxdo/services/preloaded_data_service.dart';
import 'package:fluxdo/utils/platform_utils.dart';
import 'package:fluxdo/widgets/markdown_editor/composer_submit_button.dart';
import 'package:fluxdo/widgets/post/reply_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/memory_draft_store.dart';

const _longName = 'a_really_long_username_for_testing';

Future<void> _pumpReply(
  WidgetTester tester, {
  required double width,
  String username = _longName,
}) async {
  PlatformUtils.debugDesktopOverride = false;
  addTearDown(() => PlatformUtils.debugDesktopOverride = null);
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 760);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  SharedPreferences.setMockInitialValues({'pref_use_rich_composer': false});
  final prefs = await SharedPreferences.getInstance();
  FlutterSecureStorage.setMockInitialValues({'linux_do_username': 'tester'});
  final mock = InterceptorsWrapper(
    onRequest: (options, handler) => handler.resolve(
      Response(
        requestOptions: options,
        data: {'success': 'OK', 'draft': null, 'draft_sequence': 0},
      ),
    ),
  );
  DiscourseService().dio.interceptors.insert(0, mock);
  addTearDown(() => DiscourseService().dio.interceptors.remove(mock));
  await tester.runAsync(() async {
    await PreloadedDataService().hydrateFromHtml(
      '<meta id="data-discourse-setup">'
      '<script id="data-preloaded" type="application/json">${jsonEncode({
        'currentUser': {'id': 1, 'username': 'tester'},
        'siteSettings': {'min_post_length': 1, 'max_post_length': 10000},
        'site': {'categories': [], 'top_tags': []},
      })}</script>',
    );
  });
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        localDraftStoreProvider.overrideWithValue(MemoryDraftStore()),
      ],
      child: TranslationProvider(
        child: MaterialApp(
          locale: const Locale('zh'),
          navigatorKey: navigatorKey,
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocaleUtils.supportedLocales,
          home: Scaffold(
            body: ReplySheet(
              topicId: 1,
              replyToPost: Post.fromJson({
                'id': 9,
                'post_number': 3,
                'username': username,
              }),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
}

void main() {
  testWidgets('手机宽度放不下回复对象时单独一行，名字不截断', (tester) async {
    await _pumpReply(tester, width: 360);
    final row = find.byKey(const ValueKey('reply-composer-recipient-row'));
    expect(row, findsOneWidget);
    final name = find.descendant(of: row, matching: find.text('@$_longName'));
    expect(name, findsOneWidget);
    expect(tester.widget<Text>(name).overflow, isNot(TextOverflow.ellipsis));
    expect(find.text(S.current.common_reply), findsOneWidget);
    // 发送按钮没被挤掉
    expect(find.byType(ComposerSubmitButton), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    // 草稿加载、presence 离开频道等收尾计时器跑完
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('手机宽度下短名字仍是单行页头', (tester) async {
    // 测试字体每个字符都是 1em 宽，比真机字体宽得多，这里宽度放宽一些
    await _pumpReply(tester, width: 460, username: 'Zzz_0.0');
    expect(
      find.byKey(const ValueKey('reply-composer-recipient-row')),
      findsNothing,
    );
    expect(find.text(S.current.post_replyToUser('Zzz_0.0')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('宽屏一行放得下时仍是原来的单行页头', (tester) async {
    await _pumpReply(tester, width: 900);
    expect(
      find.byKey(const ValueKey('reply-composer-recipient-row')),
      findsNothing,
    );
    expect(find.text(S.current.post_replyToUser(_longName)), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    // 草稿加载、presence 离开频道等收尾计时器跑完
    await tester.pump(const Duration(seconds: 5));
  });
}
