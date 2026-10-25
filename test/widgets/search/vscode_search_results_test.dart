import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/slang/strings.g.dart';
import 'package:fluxdo/models/category.dart';
import 'package:fluxdo/models/search_result.dart';
import 'package:fluxdo/providers/category_provider.dart';
import 'package:fluxdo/theme/vscode_theme.dart';
import 'package:fluxdo/widgets/search/vscode_search_results.dart';

SearchTopic _topic(int id, String title) => SearchTopic(
  id: id,
  title: title,
  slug: 'topic-$id',
  categoryId: 4,
  tags: const [],
  postsCount: 30,
  views: 100,
  closed: false,
  archived: false,
);

SearchPost _post(int id, {SearchTopic? topic, int floor = 1, String? blurb}) =>
    SearchPost(
      id: id,
      username: 'author-$id',
      avatarTemplate: '',
      createdAt: DateTime(2026, 10, 1),
      likeCount: 0,
      blurb: blurb ?? '第 $id 条真实搜索命中',
      postNumber: floor,
      topic: topic,
    );

Finder _group(int topicId) =>
    find.byKey(ValueKey('vscode-search-group-topic:$topicId'));
Finder _hit(int postId) => find.byKey(ValueKey('vscode-search-post-$postId'));
final _collapseAll = find.byKey(const ValueKey('vscode-search-collapse-all'));
final _expandAll = find.byKey(const ValueKey('vscode-search-expand-all'));

void main() {
  testWidgets('同话题多个命中共同折叠，重新展开后仍能看到每条命中', (tester) async {
    final topic = _topic(10, '同一个话题');
    await _pumpResults(
      tester,
      posts: [
        _post(101, topic: topic, floor: 2),
        _post(102, topic: topic, floor: 9),
      ],
    );

    expect(_hit(101).hitTestable(), findsOneWidget);
    expect(_hit(102).hitTestable(), findsOneWidget);
    await tester.tap(_group(10));
    await tester.pumpAndSettle();
    expect(_hit(101).hitTestable(), findsNothing);
    expect(_hit(102).hitTestable(), findsNothing);

    await tester.tap(_group(10));
    await tester.pumpAndSettle();
    expect(_hit(101).hitTestable(), findsOneWidget);
    expect(_hit(102).hitTestable(), findsOneWidget);
  });

  testWidgets('单击不同命中保留准确帖子对象与目标楼层，分组头不打开帖子', (tester) async {
    final topic = _topic(10, '必须定位到命中的楼层');
    final first = _post(101, topic: topic, floor: 2);
    final second = _post(102, topic: topic, floor: 17);
    final opened = <SearchPost>[];
    await _pumpResults(tester, posts: [first, second], onOpenPost: opened.add);

    await tester.tap(_hit(102));
    await tester.pump();
    expect(opened, hasLength(1));
    expect(opened.single, same(second));
    expect(opened.single.postNumber, 17);
    expect(
      find.descendant(of: _hit(101), matching: find.text('#2')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: _hit(102), matching: find.text('#17')),
      findsOneWidget,
    );
    await tester.tap(_hit(101));
    await tester.pump();
    expect(opened, orderedEquals([second, first]));
    expect(opened.last.postNumber, 2);

    await tester.tap(_group(10));
    await tester.pumpAndSettle();
    expect(opened, hasLength(2));
    expect(_hit(101).hitTestable(), findsNothing);
  });

  testWidgets('全部折叠和全部展开同时控制不同话题与用户结果', (tester) async {
    final user = SearchUser(id: 5, username: 'search-user', avatarTemplate: '');
    await _pumpResults(
      tester,
      posts: [
        _post(101, topic: _topic(10, '话题甲')),
        _post(102, topic: _topic(20, '话题乙')),
      ],
      users: [user],
    );
    final userRow = find.byKey(const ValueKey('vscode-search-user-5'));
    expect(userRow.hitTestable(), findsOneWidget);

    await tester.tap(_collapseAll);
    await tester.pumpAndSettle();
    expect(_hit(101).hitTestable(), findsNothing);
    expect(_hit(102).hitTestable(), findsNothing);
    expect(userRow.hitTestable(), findsNothing);

    await tester.tap(_expandAll);
    await tester.pumpAndSettle();
    expect(_hit(101).hitTestable(), findsOneWidget);
    expect(_hit(102).hitTestable(), findsOneWidget);
    expect(userRow.hitTestable(), findsOneWidget);
  });

  testWidgets('追加后页保留旧话题折叠状态，新话题及其命中默认可见', (tester) async {
    final topic = _topic(10, '已折叠的话题');
    final first = _post(101, topic: topic);
    final posts = await _pumpResults(tester, posts: [first]);
    await tester.tap(_group(10));
    await tester.pumpAndSettle();

    posts.value = [
      first,
      _post(102, topic: topic, floor: 7),
      _post(201, topic: _topic(20, '第二页新话题'), floor: 3),
    ];
    await tester.pumpAndSettle();
    expect(_hit(101).hitTestable(), findsNothing);
    expect(_hit(102).hitTestable(), findsNothing);
    expect(_hit(201).hitTestable(), findsOneWidget);

    await tester.tap(_group(10));
    await tester.pumpAndSettle();
    expect(_hit(101).hitTestable(), findsOneWidget);
    expect(_hit(102).hitTestable(), findsOneWidget);
    expect(_hit(201).hitTestable(), findsOneWidget);
  });

  testWidgets('摘要解码 HTML 实体且命中文本保留真实视觉高亮', (tester) async {
    await _pumpResults(
      tester,
      posts: [
        _post(
          101,
          topic: _topic(10, '高亮话题'),
          blurb:
              '前缀 &lt;标签&gt; '
              '<span class="search-highlight">命中&amp;词</span> '
              '&quot;结尾&quot;',
        ),
      ],
    );
    final richTexts = tester.widgetList<RichText>(
      find.descendant(of: _hit(101), matching: find.byType(RichText)),
    );
    final summary = richTexts.singleWhere(
      (text) => text.text.toPlainText().contains('前缀'),
    );
    expect(summary.text.toPlainText(), '前缀 <标签> 命中&词 "结尾"');
    final highlights = _spans(summary.text)
        .where((span) => span.text == '命中&词');
    expect(highlights, hasLength(1));
    expect(highlights.single.style?.backgroundColor, isNotNull);
  });

  testWidgets('未关联话题的搜索命中不丢失并能打开原始帖子', (tester) async {
    final orphan = _post(301, floor: 12, blurb: '没有 topic 关联的命中');
    final opened = <SearchPost>[];
    await _pumpResults(tester, posts: [orphan], onOpenPost: opened.add);

    await tester.tap(_hit(301));
    await tester.pump();
    expect(opened, hasLength(1));
    expect(opened.single, same(orphan));
    expect(opened.single.postNumber, 12);
  });

  testWidgets('用户结果点击打开对应用户而不是帖子', (tester) async {
    final first = SearchUser(id: 5, username: 'first-user', avatarTemplate: '');
    final second = SearchUser(
      id: 6,
      username: 'second-user',
      name: '第二位用户',
      avatarTemplate: '',
    );
    final openedUsers = <SearchUser>[];
    final openedPosts = <SearchPost>[];
    await _pumpResults(
      tester,
      posts: [],
      users: [first, second],
      onOpenUser: openedUsers.add,
      onOpenPost: openedPosts.add,
    );

    await tester.tap(find.byKey(const ValueKey('vscode-search-user-6')));
    await tester.pump();
    expect(openedUsers, hasLength(1));
    expect(openedUsers.single, same(second));
    expect(openedPosts, isEmpty);
  });

  testWidgets('330 窄栏放大文字后无溢出且命中与用户仍可操作', (tester) async {
    final post = _post(
      101,
      topic: _topic(10, '很长的话题标题在放大文字的搜索侧栏里仍然可以正常折叠与导航'),
      floor: 12345,
      blurb: '较长的摘要包含 <span class="search-highlight">搜索关键词</span> 与更多上下文内容',
    );
    final user = SearchUser(
      id: 5,
      username: 'a-very-long-search-result-username',
      name: '同样很长的用户显示名称',
      avatarTemplate: '',
    );
    final openedPosts = <SearchPost>[];
    final openedUsers = <SearchUser>[];
    await _pumpResults(
      tester,
      posts: [post],
      users: [user],
      width: 330,
      textScale: 1.8,
      onOpenPost: openedPosts.add,
      onOpenUser: openedUsers.add,
    );
    expect(tester.takeException(), isNull);
    final hitRect = tester.getRect(_hit(101));
    expect(hitRect.left, greaterThanOrEqualTo(0));
    expect(hitRect.right, lessThanOrEqualTo(330));
    expect(hitRect.width, greaterThan(150));
    await tester.tap(_hit(101));
    await tester.pump();
    expect(openedPosts.single, same(post));
    final userRow = find.byKey(const ValueKey('vscode-search-user-5'));
    await tester.ensureVisible(userRow);
    await tester.tap(userRow);
    await tester.pumpAndSettle();
    expect(openedUsers.single, same(user));
    expect(tester.takeException(), isNull);
  });
}

Iterable<TextSpan> _spans(InlineSpan span) sync* {
  if (span is TextSpan) {
    yield span;
    for (final child in span.children ?? const <InlineSpan>[]) {
      yield* _spans(child);
    }
  }
}

Future<ValueNotifier<List<SearchPost>>> _pumpResults(
  WidgetTester tester, {
  required List<SearchPost> posts,
  List<SearchUser> users = const [],
  ValueChanged<SearchPost>? onOpenPost,
  ValueChanged<SearchUser>? onOpenUser,
  double width = 600,
  double textScale = 1,
}) async {
  final source = ValueNotifier(posts);
  addTearDown(source.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        categoryMapProvider.overrideWith(
          (ref) => AsyncValue.data({
            4: Category(
              id: 4,
              name: '开发调优',
              color: '3E6C8F',
              textColor: 'FFFFFF',
              slug: 'dev',
            ),
          }),
        ),
      ],
      child: TranslationProvider(
        child: MaterialApp(
          locale: const Locale('zh'),
          supportedLocales: AppLocaleUtils.supportedLocales,
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          theme: ThemeData(extensions: [VscodeTokens.of(Brightness.light)]),
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: width,
                child: MediaQuery(
                  data: MediaQueryData(
                    textScaler: TextScaler.linear(textScale),
                  ),
                  child: _ResultsHost(
                    posts: source,
                    users: users,
                    onOpenPost: onOpenPost ?? (_) {},
                    onOpenUser: onOpenUser ?? (_) {},
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return source;
}

class _ResultsHost extends StatefulWidget {
  const _ResultsHost({
    required this.posts,
    required this.users,
    required this.onOpenPost,
    required this.onOpenUser,
  });

  final ValueNotifier<List<SearchPost>> posts;
  final List<SearchUser> users;
  final ValueChanged<SearchPost> onOpenPost;
  final ValueChanged<SearchUser> onOpenUser;

  @override
  State<_ResultsHost> createState() => _ResultsHostState();
}

class _ResultsHostState extends State<_ResultsHost> {
  final _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      ValueListenableBuilder<List<SearchPost>>(
        valueListenable: widget.posts,
        builder: (context, posts, _) => VscodeSearchResults(
          posts: posts,
          users: widget.users,
          scrollController: _scrollController,
          footer: const SizedBox.shrink(),
          hasMorePosts: true,
          onOpenPost: widget.onOpenPost,
          onOpenUser: widget.onOpenUser,
        ),
      );
}
