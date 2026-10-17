import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/models/category.dart';
import 'package:fluxdo/models/topic.dart';
import 'package:fluxdo/theme/mojian_theme.dart';
import 'package:fluxdo/widgets/topic/painted_topic_card.dart';
import 'package:fluxdo/widgets/topic/topic_card_layout.dart';

ThemeData _mojianTheme(Brightness b) => MojianTheme.build(
  scheme: MojianTheme.colorScheme(b, MojianAccent.cinnabar),
  accent: MojianAccent.cinnabar,
  fontFamily: null,
  pageTransitionsTheme: const PageTransitionsTheme(),
  iconTheme: const IconThemeData(),
  primaryIconTheme: const IconThemeData(),
);

Topic _topic({
  int unread = 0,
  bool unseen = false,
  bool solved = false,
  int? lastRead,
}) => Topic(
  id: 4242,
  title: '用了三个月 N100 小主机当家庭服务器，聊聊功耗、噪音和那些踩过的坑',
  slug: 'n100',
  postsCount: 129,
  replyCount: 128,
  views: 12640,
  likeCount: 846,
  categoryId: '4',
  tags: const [
    Tag(name: '硬件'),
    Tag(name: 'NAS'),
  ],
  unread: unread,
  unseen: unseen,
  hasAcceptedAnswer: solved,
  lastReadPostNumber: lastRead,
);

final _category = Category(
  id: 4,
  name: '开发调优',
  color: '3E6C8F',
  textColor: 'FFFFFF',
  slug: 'dev',
);

TopicCardLayout _layout(
  ThemeData theme,
  Topic topic, {
  String Function(int)? label,
}) {
  TopicCardLayout.evictAll();
  return TopicCardLayout.obtain(
    identity: 'test:${topic.id}:${theme.brightness}',
    topic: topic,
    width: 380,
    theme: theme,
    category: _category,
    emojiUrlOf: (_) => '',
    statsAvailableWidth: 320,
    newRepliesLabel: label,
  );
}

void main() {
  group('墨笺话题行排版', () {
    test('平铺行：无卡间距、有分隔线、分类在标题上方、头像 18', () {
      final l = _layout(_mojianTheme(Brightness.light), _topic());
      expect(l.mojian, isTrue);
      expect(l.bottomGap, 0);
      expect(l.separatorColor, isNotNull);
      expect(l.cardColor, Colors.transparent);
      expect(l.catTags, isNotNull);
      expect(l.catTagsOffset.dy, lessThan(l.titleOffset.dy));
      expect(l.avatarRect.width, 18);
      expect(l.avatarRect.top, greaterThan(l.titleOffset.dy));
      // 时间紧跟署名之后
      expect(l.timeOffset.dx, greaterThan(l.authorOffset.dx));
      expect(l.cardHeight, greaterThan(60));
    });

    test('未读：标题前强调色圆点，元信息行出「N 条新回复」', () {
      final theme = _mojianTheme(Brightness.light);
      final l = _layout(theme, _topic(unread: 3), label: (n) => '$n 条新回复');
      final accent = theme.extension<MojianTokens>()!.accent;
      expect(l.extraFills.where((f) => f.$2 == accent), hasLength(1));
      expect(l.extraTexts, isNotEmpty);
      // 标题行右侧不再放经典的未读徽章
      expect(
        l.extraFills.where((f) => f.$1.width > 10 && f.$2 == accent),
        isEmpty,
      );
    });

    test('已读行退后:分类方点变淡', () {
      final theme = _mojianTheme(Brightness.light);
      final fresh = _layout(theme, _topic()).categoryDotColor!;
      final read = _layout(theme, _topic(lastRead: 129)).categoryDotColor!;
      expect(read.a, lessThan(fresh.a));
    });

    test('经典风格不受影响', () {
      final classic = ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
      );
      final l = _layout(classic, _topic(unread: 3));
      expect(l.mojian, isFalse);
      expect(l.bottomGap, 8);
      expect(l.separatorColor, isNull);
      expect(l.avatarRect.width, 32);
    });
  });

  testWidgets('墨笺话题行在深浅两色下都能挂载绘制', (tester) async {
    for (final b in Brightness.values) {
      final theme = _mojianTheme(b);
      final l = _layout(theme, _topic(unseen: true, solved: true));
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 380,
                child: PaintedTopicCard(layout: l, isSelected: true),
              ),
            ),
          ),
        ),
      );
      final size = tester.getSize(find.byType(PaintedTopicCard));
      expect(size.height, closeTo(l.cardHeight, 0.5));
      expect(tester.takeException(), isNull);
    }
  });
}
