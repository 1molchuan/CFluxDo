import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/models/topic.dart';
import 'package:fluxdo/models/vscode_body_style.dart';
import 'package:fluxdo/providers/preferences_provider.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/settings/definitions/appearance_defs.dart';
import 'package:fluxdo/settings/settings_renderer.dart';
import 'package:fluxdo/theme/vscode_theme.dart';
import 'package:fluxdo/theme/mojian_theme.dart';
import 'package:fluxdo/widgets/post/post_item/widgets/vscode_post_source.dart';
import 'package:shared_preferences/shared_preferences.dart';

Post _post(int number, String html) => Post(
  id: number,
  username: 'alice',
  avatarTemplate: '',
  cooked: html,
  postNumber: number,
  postType: 1,
  createdAt: DateTime(2026, 10, 25),
  updatedAt: DateTime(2026, 10, 25),
  replyCount: 0,
  likeCount: 0,
);

Future<ProviderContainer> _pump(
  WidgetTester tester, {
  required SharedPreferences prefs,
  Post? post,
  bool settings = false,
  Brightness brightness = Brightness.light,
}) async {
  late ProviderContainer container;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      child: TranslationProvider(
        child: MaterialApp(
          locale: const Locale('zh'),
          supportedLocales: AppLocaleUtils.supportedLocales,
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          theme: ThemeData(extensions: [VscodeTokens.of(brightness)]),
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) {
                container = ProviderScope.containerOf(context);
                if (settings) {
                  final group = buildAppearanceGroups(context).firstWhere(
                    (group) =>
                        group.title == context.l10n.appearance_vscodeBody,
                  );
                  return ListView(
                    children: [
                      if (group.isVisible(ref))
                        for (final item in group.items)
                          SettingsRenderer(model: item),
                    ],
                  );
                }
                return SingleChildScrollView(
                  child: VscodePostSource(
                    post: post!,
                    topicId: 10,
                    document: VscodeSourceDocument.forHtml(post.cooked),
                    richTextBuilder: (_) => const Text('原文区'),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

Finder _line(String text) => find.byWidgetPredicate(
  (widget) =>
      widget is Text &&
      (widget.data ??
                  widget.textSpan?.toPlainText(includeSemanticsLabels: false))
              ?.trimLeft() ==
          text.trimLeft(),
);

void main() {
  for (final brightness in Brightness.values) {
    for (final language in VscodeCodeLanguage.values) {
      testWidgets('$brightness $language 的整条正文注释使用注释色并保留链接', (tester) async {
        SharedPreferences.setMockInitialValues({
          'pref_vscode_body_style': 'programming',
          'pref_vscode_code_language': language.name,
        });
        final prefs = await SharedPreferences.getInstance();
        await _pump(
          tester,
          prefs: prefs,
          brightness: brightness,
          post: _post(
            1,
            '<p>正文 <strong>重点</strong> <code>value</code> '
            '<a href="https://example.com">文档</a></p>'
            '<pre><code>return "text";</code></pre>',
          ),
        );
        final marker = language == VscodeCodeLanguage.python ? '#' : '//';
        for (final content in ['正文 重点 value 文档', 'return "text";']) {
          final text = tester.widget<Text>(_line('$marker $content'));
          final spans = (text.textSpan! as TextSpan).children!.cast<TextSpan>();
          for (final span in spans) {
            expect(
              span.style!.color,
              VscodeTokens.of(brightness).syntaxComment,
            );
          }
          if (content.startsWith('正文')) {
            final link = spans.firstWhere((span) => span.text == '文档');
            expect(link.recognizer, isNotNull);
            expect(link.style!.decoration, TextDecoration.underline);
          }
        }
        if (language == VscodeCodeLanguage.python) {
          final end = tester.widget<Text>(_line('# end of topic'));
          expect(
            ((end.textSpan! as TextSpan).children!.single as TextSpan)
                .style!
                .color,
            VscodeTokens.of(brightness).syntaxComment,
          );
        }
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }
  testWidgets('代码式首帖与回复按语言切换，手动原文不遮盖新选择', (tester) async {
    SharedPreferences.setMockInitialValues({
      'pref_vscode_body_style': 'programming',
    });
    final prefs = await SharedPreferences.getInstance();
    final root = _post(1, '<p>完整中文正文</p>');
    final container = await _pump(tester, prefs: prefs, post: root);
    expect(_line('public class Topic {'), findsOneWidget);
    expect(_line('// @alice · #1'), findsOneWidget);
    expect(_line('  // 完整中文正文'), findsOneWidget);

    await tester.tap(find.byTooltip('查看原文'));
    await tester.pump();
    expect(find.text('原文区'), findsOneWidget);
    await container
        .read(preferencesProvider.notifier)
        .setVscodeCodeLanguage(VscodeCodeLanguage.python);
    await tester.pump();
    expect(find.text('原文区'), findsNothing);
    expect(_line('class Topic:'), findsOneWidget);
    expect(_line('# @alice · #1'), findsOneWidget);
    expect(_line('    # 完整中文正文'), findsOneWidget);
    expect(_line('public class Topic {'), findsNothing);

    await _pump(tester, prefs: prefs, post: _post(2, '<p>回复中文</p>'));
    expect(_line('def reply_alice_2(self):'), findsOneWidget);
    expect(_line('    return None'), findsOneWidget);
    expect(_line('class Topic:'), findsNothing);
    await container
        .read(preferencesProvider.notifier)
        .setVscodeBodyStyle(VscodeBodyStyle.compact);
    await tester.pump();
    expect(_line('回复中文'), findsOneWidget);
    expect(_line('def reply_alice_2(self):'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('隐藏正文始终走原文门禁，代码模式不提供绕过按钮', (tester) async {
    SharedPreferences.setMockInitialValues({
      'pref_vscode_body_style': 'programming',
      'pref_vscode_code_language': 'python',
    });
    final prefs = await SharedPreferences.getInstance();
    await _pump(
      tester,
      prefs: prefs,
      post: _post(1, '<details><summary>折叠</summary>秘密正文</details>'),
    );
    expect(find.text('原文区'), findsOneWidget);
    expect(_line('    # 秘密正文'), findsNothing);
    expect(find.byType(IconButton), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('设置仅在 VS Code 下显示，语言按需出现且重新创建后保留', (tester) async {
    SharedPreferences.setMockInitialValues({'ui_style': 'vscode'});
    final prefs = await SharedPreferences.getInstance();
    var container = await _pump(tester, prefs: prefs, settings: true);
    expect(find.byType(DropdownButton<VscodeCodeLanguage>), findsNothing);
    await tester.tap(find.byType(DropdownButton<VscodeBodyStyle>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('编程语言').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButton<VscodeCodeLanguage>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Python').last);
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
    container = await _pump(tester, prefs: prefs, settings: true);
    expect(
      tester
          .widget<DropdownButton<VscodeBodyStyle>>(
            find.byType(DropdownButton<VscodeBodyStyle>),
          )
          .value,
      VscodeBodyStyle.programming,
    );
    expect(
      tester
          .widget<DropdownButton<VscodeCodeLanguage>>(
            find.byType(DropdownButton<VscodeCodeLanguage>),
          )
          .value,
      VscodeCodeLanguage.python,
    );
    await container.read(themeProvider.notifier).setUiStyle(UiStyle.claude);
    await tester.pumpAndSettle();
    expect(find.byType(DropdownButton<VscodeBodyStyle>), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('编程式正文显示可见格式，不暴露 Markdown 编码或链接地址', (tester) async {
    SharedPreferences.setMockInitialValues({
      'pref_vscode_body_style': 'programming',
    });
    final prefs = await SharedPreferences.getInstance();
    await _pump(
      tester,
      prefs: prefs,
      post: _post(
        2,
        '<p>阅读 <strong>重点</strong> 和 <a href="https://example.com/long/path">文档</a>，'
        '<em>斜体</em>、<del>删除</del>、<code>x &lt; 2</code>。</p>'
        '<p></p><p>第二段</p><pre><code>  alpha();\n\n  beta();\n</code></pre>',
      ),
    );
    final text = tester.widget<Text>(
      find.byWidgetPredicate(
        (widget) =>
            widget is Text &&
            widget.textSpan
                    ?.toPlainText(includeSemanticsLabels: false)
                    .trimLeft() ==
                '// 阅读 重点 和 文档，斜体、删除、x < 2。',
      ),
    );
    final spans = (text.textSpan! as TextSpan).children!.cast<TextSpan>();
    expect(
      spans.firstWhere((span) => span.text == '重点').style!.fontWeight,
      FontWeight.w600,
    );
    expect(
      spans.firstWhere((span) => span.text == '斜体').style!.fontStyle,
      FontStyle.italic,
    );
    expect(
      spans.firstWhere((span) => span.text == '删除').style!.decoration,
      TextDecoration.lineThrough,
    );
    expect(_line('  // 第二段'), findsOneWidget);
    expect(_line('  //   alpha();'), findsOneWidget);
    expect(_line('  //   beta();'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('引用头像和分类图标不混入正文，也不破坏代码式区块', (tester) async {
    SharedPreferences.setMockInitialValues({
      'pref_vscode_body_style': 'programming',
    });
    final prefs = await SharedPreferences.getInstance();
    await _pump(
      tester,
      prefs: prefs,
      post: _post(
        2,
        '<aside class="quote"><div class="title">'
        '<img class="avatar" src="https://example.com/avatar.png">'
        '<a href="/t/topic/1">引用标题</a></div>'
        '<blockquote><p>被引用正文</p></blockquote></aside>'
        '<p>参见 <a class="hashtag-cooked" href="/c/feedback/126">'
        '<svg class="fa d-icon"><use href="#square-full"></use></svg>'
        '<span>iOS App</span></a> 版块</p>',
      ),
    );
    expect(_line('  // > 被引用正文'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Text &&
            widget.textSpan
                    ?.toPlainText(includeSemanticsLabels: false)
                    .trimLeft() ==
                '// 参见 iOS App 版块',
      ),
      findsOneWidget,
    );
    expect(find.text('原文区'), findsNothing);
    expect(find.textContaining('[图片]', findRichText: true), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('编程式引用移除本地包装但保留 Markdown 与链接', () {
    final document = VscodeSourceDocument.forPost(
      _post(2, '<p>正文</p>'),
      style: VscodeBodyStyle.programming,
    );
    expect(
      document.quoteText(
        '// @alice · #2\npublic void reply_alice_2() {\n  // 正文\n  // [链接](https://example.com)\n}',
      ),
      '正文\n[链接](https://example.com)',
    );
    expect(document.quoteText('  // **加粗**'), '**加粗**');
  });

  test('作者元信息仅首块生成，简洁与 Python 引用均过滤元信息', () {
    for (final style in VscodeBodyStyle.values) {
      for (final language in VscodeCodeLanguage.values) {
        final post = _post(2, '<p>正文</p>');
        final first = VscodeSourceDocument.forPost(
          post,
          style: style,
          language: language,
          lastUnit: false,
        );
        final marker = language == VscodeCodeLanguage.python ? '#' : '//';
        final author = '$marker @alice · #2';
        expect(first.quoteText('$author\n正文'), '正文');
        expect(first.quoteText(author), isNull);
      }
    }
  });

  test('非法存储值不会阻断加载且可保存有效模式', () async {
    SharedPreferences.setMockInitialValues({
      'pref_vscode_body_style': 7,
      'pref_vscode_code_language': 'unknown',
    });
    final prefs = await SharedPreferences.getInstance();
    final notifier = PreferencesNotifier(prefs);
    addTearDown(notifier.dispose);
    expect(notifier.state.vscodeBodyStyle, VscodeBodyStyle.compact);
    expect(notifier.state.vscodeCodeLanguage, VscodeCodeLanguage.java);
    await notifier.setVscodeBodyStyle(VscodeBodyStyle.programming);
    await notifier.setVscodeCodeLanguage(VscodeCodeLanguage.python);
    final restored = PreferencesNotifier(prefs);
    addTearDown(restored.dispose);
    expect(restored.state.vscodeBodyStyle, VscodeBodyStyle.programming);
    expect(restored.state.vscodeCodeLanguage, VscodeCodeLanguage.python);
  });
}
