import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/models/category.dart';
import 'package:fluxdo/models/topic.dart';
import 'package:fluxdo/services/local_notification_service.dart';
import 'package:fluxdo/theme/vscode_theme.dart';
import 'package:fluxdo/widgets/topic/vscode_topic_row.dart';

final _category = Category(
  id: 4,
  name: '开发调优',
  color: '3E6C8F',
  textColor: 'FFFFFF',
  slug: 'dev',
);

Topic _topic() => Topic(
  id: 42,
  title: '很长的话题标题在窄侧栏中仍然优先展示，不被作者和分类挤占',
  slug: 'dense-topic',
  postsCount: 43,
  replyCount: 42,
  views: 100,
  likeCount: 3,
  categoryId: '4',
  pinned: true,
  closed: true,
  unread: 2,
  lastPostedAt: DateTime.now().subtract(const Duration(hours: 1)),
  posters: [
    TopicPoster(
      userId: 1,
      description: '',
      extras: '',
      user: TopicUser(
        id: 1,
        username: 'actual-author',
        name: '真实作者',
        avatarTemplate: '',
      ),
    ),
  ],
);

Widget _app(Widget child, {double width = 230, double textScale = 1}) =>
    TranslationProvider(
      child: MaterialApp(
        navigatorKey: navigatorKey,
        locale: const Locale('zh'),
        supportedLocales: AppLocaleUtils.supportedLocales,
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        theme: ThemeData(extensions: [VscodeTokens.of(Brightness.light)]),
        home: Scaffold(
          body: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(width: width, child: child),
            ),
          ),
        ),
      ),
    );

void main() {
  testWidgets('窄侧栏放大文字后标题仍有可读空间且状态不被挤出', (tester) async {
    final topic = _topic();
    await tester.pumpWidget(
      _app(
        VscodeTopicRow(
          topic: topic,
          category: _category,
          isSelected: true,
          onTap: () {},
        ),
        textScale: 1.6,
      ),
    );

    expect(find.text(topic.title), findsOneWidget);
    expect(find.byIcon(Icons.push_pin_outlined), findsOneWidget);
    expect(find.byIcon(Icons.lock_outline), findsOneWidget);
    final titleRect = tester.getRect(find.text(topic.title));
    final lockRect = tester.getRect(find.byIcon(Icons.lock_outline));
    expect(titleRect.width, greaterThan(90));
    expect(titleRect.right, lessThan(lockRect.left));
    expect(lockRect.right, lessThanOrEqualTo(230));
    expect(tester.takeException(), isNull);
  });
}
