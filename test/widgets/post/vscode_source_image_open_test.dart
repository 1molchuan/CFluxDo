import 'package:extended_image_lite/extended_image_lite.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/models/topic.dart';
import 'package:fluxdo/models/vscode_body_style.dart';
import 'package:fluxdo/pages/image_viewer_page.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/services/local_notification_service.dart'
    show navigatorKey;
import 'package:fluxdo/services/discourse_cache_manager.dart';
import 'package:fluxdo/theme/vscode_theme.dart';
import 'package:fluxdo/widgets/content/discourse_image.dart';
import 'package:fluxdo/widgets/content/discourse_html_content/image_utils.dart';
import 'package:fluxdo/widgets/layout/vscode_reader_status_scope.dart';
import 'package:fluxdo/widgets/post/post_item/widgets/post_segment_frame.dart';
import 'package:fluxdo/widgets/post/post_item/widgets/vscode_post_source.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _thumbnail =
    'https://images.example.com/uploads/default/optimized/3X/a/b/preview_2_320x180.png';
const _original = 'https://images.example.com/full-size.png';
const _other = 'https://images.example.com/other.png';
const _label = '图片标签';
const _imageHtml =
    '<p><a href="$_original">同址文字</a></p>'
    '<div class="lightbox-wrapper"><a class="lightbox" href="$_original" title="$_label">'
    '<img src="$_thumbnail" alt="$_label" width="320" height="180"></a></div>';
const _otherHtml =
    '<a class="lightbox" href="$_other"><img src="$_other" alt="第二张"></a>';

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

Future<void> _pumpSource(
  WidgetTester tester, {
  required VscodeBodyStyle style,
  required VscodeCodeLanguage language,
  required GlobalKey<NavigatorState> navigator,
  required ValueNotifier<int?> selected,
  required ScrollController scroll,
  int number = 1,
  bool middleUnit = false,
  String html = _imageHtml,
}) async {
  // 沿用图片组件测试的缓存目录隔离：真实查看器和 ImageProvider 继续消费 URL，
  // 仅阻断图片 IO，不访问外网或本机缓存，也不替换路由/打开图片回调。
  const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    pathChannel,
    (_) async => throw PlatformException(code: 'test-image-io-disabled'),
  );
  addTearDown(() {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      pathChannel,
      null,
    );
  });
  SharedPreferences.setMockInitialValues({
    'pref_vscode_body_style': style.name,
    'pref_vscode_code_language': language.name,
  });
  final prefs = await SharedPreferences.getInstance();
  final post = _post(number, '$_otherHtml$html');
  await tester.pumpWidget(
    ProviderScope(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      child: TranslationProvider(
        child: MaterialApp(
          navigatorKey: navigator,
          locale: const Locale('zh'),
          supportedLocales: AppLocaleUtils.supportedLocales,
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          theme: ThemeData(extensions: [VscodeTokens.of(Brightness.light)]),
          home: Scaffold(
            body: VscodeReaderFlowScope(
              selectedPost: selected,
              child: SingleChildScrollView(
                controller: scroll,
                child: Column(
                  children: [
                    const SizedBox(height: 240),
                    PostSegmentFrame(
                      post: post,
                      selected: false,
                      highlight: false,
                      child: VscodePostSource(
                        post: post,
                        topicId: 10,
                        document: VscodeSourceDocument.forHtml(html),
                        firstUnit: !middleUnit,
                        lastUnit: !middleUnit,
                        richTextBuilder: (_) => const Text('原文区'),
                      ),
                    ),
                    const SizedBox(height: 1000),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  scroll.jumpTo(160);
  await tester.pump();
}

Offset _textPoint(WidgetTester tester, String label) {
  final text = find.byWidgetPredicate(
    (widget) =>
        widget is Text &&
        widget.textSpan
                ?.toPlainText(includeSemanticsLabels: false)
                .contains(label) ==
            true,
  );
  final richText = find.descendant(of: text, matching: find.byType(RichText));
  final paragraph = tester.renderObject<RenderParagraph>(richText);
  final plain = paragraph.text.toPlainText(includeSemanticsLabels: false);
  final start = plain.indexOf(label);
  final box = paragraph
      .getBoxesForSelection(
        TextSelection(baseOffset: start, extentOffset: start + 1),
      )
      .first;
  return paragraph.localToGlobal(box.toRect().center);
}

ImageProvider _unwrap(ImageProvider provider) {
  while (provider is ResizeImage) {
    provider = provider.imageProvider;
  }
  return provider;
}

// 图片 IO 刻意禁用，加载动画不会停止；仅推进路由及提示框的有限动画。
Future<void> _pumpImageFrames(WidgetTester tester) async {
  for (var frame = 0; frame < 10; frame++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  for (final scenario in [
    (
      VscodeBodyStyle.compact,
      VscodeCodeLanguage.java,
      1,
      false,
      PointerDeviceKind.mouse,
    ),
    (
      VscodeBodyStyle.programming,
      VscodeCodeLanguage.java,
      1,
      false,
      PointerDeviceKind.mouse,
    ),
    (
      VscodeBodyStyle.programming,
      VscodeCodeLanguage.python,
      2,
      false,
      PointerDeviceKind.touch,
    ),
    (
      VscodeBodyStyle.programming,
      VscodeCodeLanguage.java,
      2,
      true,
      PointerDeviceKind.mouse,
    ),
  ]) {
    testWidgets(
      '${scenario.$1} ${scenario.$2} #${scenario.$3} 分段${scenario.$4} 图片直接打开真实原图画廊',
      (tester) async {
        final navigator = navigatorKey;
        final selected = ValueNotifier<int?>(null);
        final scroll = ScrollController();
        addTearDown(selected.dispose);
        addTearDown(scroll.dispose);
        await _pumpSource(
          tester,
          style: scenario.$1,
          language: scenario.$2,
          navigator: navigator,
          selected: selected,
          scroll: scroll,
          number: scenario.$3,
          middleUnit: scenario.$4,
        );
        final offset = scroll.offset;
        // 文字与图片 URL 相同且文字先创建，普通点击仍不能复用图片的激活模式。
        final pointer = await tester.createGesture(kind: scenario.$5);
        await pointer.down(_textPoint(tester, '同址文字'));
        await pointer.up();
        await pointer.removePointer();
        await tester.pumpAndSettle();
        expect(find.byType(ImageViewerPage), findsNothing);
        selected.value = null;
        // 与前面的文字点击分开，避免触摸选择器将两次操作识别为双击。
        await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 1));

        await tester.tapAt(_textPoint(tester, _label), kind: scenario.$5);
        await _pumpImageFrames(tester);
        expect(find.byType(ImageViewerPage), findsOneWidget);
        expect(selected.value, scenario.$3);
        expect(find.text('2 / 2'), findsOneWidget);
        final consumed = tester
            .widgetList<GestureImageView>(
              find.descendant(
                of: find.byType(ImageViewerPage),
                matching: find.byType(GestureImageView),
              ),
            )
            .map((image) => _unwrap(image.image))
            .whereType<BlobImageProvider>();
        expect(
          consumed.any(
            (image) =>
                image.url == _original &&
                image.bucket == BlobImageCache.originalBucket,
          ),
          isTrue,
        );
        if (scenario.$1 == VscodeBodyStyle.compact) {
          final gallery = find.byType(ExtendedImageGesturePageView);
          await tester.drag(gallery, const Offset(600, 0));
          await _pumpImageFrames(tester);
          expect(find.text('1 / 2'), findsOneWidget);
          await tester.drag(gallery, const Offset(-600, 0));
          await _pumpImageFrames(tester);
          expect(find.text('2 / 2'), findsOneWidget);
        }

        navigator.currentState!.pop();
        await _pumpImageFrames(tester);
        expect(find.byType(ImageViewerPage), findsNothing);
        expect(selected.value, scenario.$3);
        expect(scroll.offset, offset);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  for (final source in [
    (
      '<a class="lightbox" href="upload://SourceViewerRegression.png" title="$_label">'
          '<img src="$_thumbnail" alt="$_label"></a>',
      _original,
    ),
    (
      '<img src="$_thumbnail" alt="$_label">',
      'https://images.example.com/uploads/default/original/3X/a/b/preview.png',
    ),
  ]) {
    testWidgets('原图解析实际进入查看器：${source.$2}', (tester) async {
      DiscourseImageUtils.seedUploadUrl(
        'upload://SourceViewerRegression.png',
        _original,
      );
      final selected = ValueNotifier<int?>(null);
      final scroll = ScrollController();
      addTearDown(selected.dispose);
      addTearDown(scroll.dispose);
      await _pumpSource(
        tester,
        style: VscodeBodyStyle.compact,
        language: VscodeCodeLanguage.java,
        navigator: navigatorKey,
        selected: selected,
        scroll: scroll,
        html: source.$1,
      );
      await tester.tapAt(_textPoint(tester, _label));
      await _pumpImageFrames(tester);
      expect(find.byType(ImageViewerPage), findsOneWidget);
      final consumed = tester
          .widgetList<GestureImageView>(
            find.descendant(
              of: find.byType(ImageViewerPage),
              matching: find.byType(GestureImageView),
            ),
          )
          .map((image) => _unwrap(image.image))
          .whereType<BlobImageProvider>();
      expect(
        consumed.any(
          (image) =>
              image.url == source.$2 &&
              image.bucket == BlobImageCache.originalBucket,
        ),
        isTrue,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('拖选图片标签与右键不误开图，悬停仍显示缩略图', (tester) async {
    final selected = ValueNotifier<int?>(null);
    final scroll = ScrollController();
    addTearDown(selected.dispose);
    addTearDown(scroll.dispose);
    await _pumpSource(
      tester,
      style: VscodeBodyStyle.programming,
      language: VscodeCodeLanguage.java,
      navigator: navigatorKey,
      selected: selected,
      scroll: scroll,
    );
    final point = _textPoint(tester, _label);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.down(point - const Offset(12, 0));
    await mouse.moveTo(point + const Offset(60, 0));
    await mouse.up();
    await tester.pumpAndSettle();
    expect(find.byType(ImageViewerPage), findsNothing);
    expect(selected.value, isNull);

    final secondary = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await secondary.down(point);
    await secondary.up();
    await mouse.removePointer();
    await secondary.removePointer();
    await tester.pumpAndSettle();
    expect(find.byType(ImageViewerPage), findsNothing);

    // 清除右键菜单和选区，再检查实际 Tooltip 中仍挂载预览图片。
    await tester.tapAt(const Offset(750, 550));
    await tester.pumpAndSettle();
    final hover = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await hover.addPointer(location: Offset.zero);
    await hover.moveTo(point);
    await tester.pump(const Duration(seconds: 1));
    await _pumpImageFrames(tester);
    expect(
      find.byWidgetPredicate(
        (widget) => widget is DiscourseImage && widget.url == _thumbnail,
      ),
      findsOneWidget,
    );
    expect(find.byType(ImageViewerPage), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
