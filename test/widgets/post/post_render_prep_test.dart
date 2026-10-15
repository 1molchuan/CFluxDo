// 预热 key 输入 == 挂载 key 输入。
//
// 滚动顺滑靠预热把段落 flatten / 排版提前做进全局缓存;缓存 key 含
// (inlines 身份, totalImagesInPost, 样式, 主题, flattener)。预热侧与挂载侧
// 只要有一项不同源,预热就静默白做 —— cc90e99d 之前预热固定传
// totalImagesInPost 0,挂载侧是 countImageRuns(nodes),带图楼层全部白做。
//
// 这里对四类楼层(带图、短帖、长帖分块、系统帖)分别从两侧取 key 输入:
// - 预热侧:PostRenderPrep.warmOneUnit 实际交给段落预热器的单位;
// - 挂载侧:真实挂载 widget(PostItem / NewEngineChunkSegment)构造出的
//   FluxdoRender 的 parsedNodes,图片数按 FluxdoRender 内部同式
//   countImageRuns(parsedNodes) 算。
// 再加一条端到端:经生产预热器热过之后挂载,FlattenCache 零 miss。
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/models/topic.dart';
import 'package:fluxdo/providers/theme_provider.dart'
    show sharedPreferencesProvider;
import 'package:fluxdo/services/local_notification_service.dart';
import 'package:fluxdo/widgets/post/post_item/post_item.dart';
import 'package:fluxdo/widgets/post/post_item/post_render_prep.dart';
import 'package:fluxdo/widgets/post/post_item/render_parse_cache.dart';
import 'package:fluxdo/widgets/post/post_item/segmented_long_post.dart';
import 'package:fluxdo/widgets/post/small_action_item.dart';
import 'package:fluxdo_render/fluxdo_render.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _img =
    '<img src="https://linux.do/uploads/default/original/1X/abc.png" '
    'alt="abc" width="690" height="388">';

Post _post({
  required int id,
  required String cooked,
  int postType = 1,
  String? actionCode,
}) {
  return Post(
    id: id,
    username: 'user$id',
    avatarTemplate: '',
    cooked: cooked,
    postNumber: id,
    postType: postType,
    updatedAt: DateTime(2026),
    createdAt: DateTime(2026),
    likeCount: 0,
    replyCount: 0,
    actionCode: actionCode,
  );
}

/// 长帖:30 段、每段百余字,第 13 / 21 / 27 段带图 —— 切成多块,且后面
/// 的块图片偏移非 0(按 chunk 分别计数才对得上挂载)
String _longCooked() {
  final buf = StringBuffer();
  for (var i = 0; i < 30; i++) {
    final image = i == 13 || i == 21 || i == 27 ? ' $_img' : '';
    buf.write(
      '<p>第 $i 段:这是一段用来把帖子撑到分块阈值以上的正文,'
      '内容本身无所谓,长度够就行。再补一句凑够字数,让每段都有一百多字。$image</p>',
    );
  }
  return buf.toString();
}

/// 测试用 id 互不重复(RenderParseCache 是全局 LRU,跨用例共享)
int _nextId = 9000;
int _id() => _nextId++;

Post _shortPost() => _post(id: _id(), cooked: '<p>普通短帖第一段</p><p>第二段,没有图</p>');

Post _imagePost() => _post(
  id: _id(),
  cooked: '<p>看这张图 $_img 很好看</p><p>第二段文字</p><p>第三段 $_img</p>',
);

Post _longPost() => _post(id: _id(), cooked: _longCooked());

/// discourse-assign 的指定帖:whisper + action_code,cooked 长过分块阈值
Post _systemPost() => _post(
  id: _id(),
  cooked: _longCooked(),
  postType: PostTypes.whisper,
  actionCode: 'assigned',
);

/// 预热侧:把 [plan] 从头热到尾,记下段落预热器收到的每个单位
List<PostRenderUnit> _warmUnitsOf(PostRenderPlan plan) {
  final seen = <PostRenderUnit>[];
  final cursor = PostWarmCursor();
  final budget = WarmBudget(1 << 40, () => 0);
  for (var step = 0; step < 1000; step++) {
    final outcome = PostRenderPrep.warmOneUnit(
      plan,
      cursor,
      budget,
      paragraphWarmer: () =>
          (unit, {required startIndex, required budgetMicros}) {
            seen.add(unit);
            return -1;
          },
    );
    if (outcome == PostWarmOutcome.done) return seen;
  }
  fail('预热没有收敛');
}

final _theme = ThemeData();

Widget _host(SharedPreferences prefs, Widget child) {
  return ProviderScope(
    overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
    child: TranslationProvider(
      child: MaterialApp(
        locale: const Locale('zh'),
        navigatorKey: navigatorKey,
        theme: _theme,
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocaleUtils.supportedLocales,
        home: Scaffold(body: SingleChildScrollView(child: child)),
      ),
    ),
  );
}

/// 长帖挂载侧:与 TopicPostList 分段同一接法(unit = plan.unitAt(ci))
Widget _chunkSegment(Post post, PostRenderPlan plan, int ci) {
  return NewEngineChunkSegment(
    post: post,
    topicId: 1,
    selected: false,
    highlight: false,
    unit: plan.unitAt(ci),
    callbacks: plan.longData!.callbacks,
    onQuoteSelection: null,
  );
}

FluxdoRender _mountedRender(WidgetTester tester) =>
    tester.widget<FluxdoRender>(find.byType(FluxdoRender));

void main() {
  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  group('预热 key 输入 == 挂载 key 输入', () {
    testWidgets('带图短帖:nodes 同一实例,图片数同式且非 0', (tester) async {
      final post = _imagePost();
      final plan = PostRenderPrep.planFor(post, topicId: 1);
      expect(plan.kind, PostRenderKind.short);

      final warmed = _warmUnitsOf(plan);
      expect(warmed, hasLength(1));
      // 夹具自检:这一楼确实带图(否则测不出 cc90e99d 那类回归)
      expect(warmed.single.totalImagesInPost, 2);

      await tester.pumpWidget(_host(prefs, PostItem(post: post, topicId: 1)));
      final mounted = _mountedRender(tester);
      expect(identical(mounted.parsedNodes, warmed.single.nodes), isTrue);
      expect(
        countImageRuns(mounted.parsedNodes!),
        warmed.single.totalImagesInPost,
      );
      expect(mounted.imageIndexOffset, warmed.single.imageIndexOffset);
    });

    testWidgets('无图短帖', (tester) async {
      final post = _shortPost();
      final plan = PostRenderPrep.planFor(post, topicId: 1);
      expect(plan.kind, PostRenderKind.short);

      final warmed = _warmUnitsOf(plan);
      expect(warmed, hasLength(1));

      await tester.pumpWidget(_host(prefs, PostItem(post: post, topicId: 1)));
      final mounted = _mountedRender(tester);
      expect(identical(mounted.parsedNodes, warmed.single.nodes), isTrue);
      expect(countImageRuns(mounted.parsedNodes!), 0);
      expect(warmed.single.totalImagesInPost, 0);
    });

    testWidgets('长帖:逐 chunk 同源,图片数按 chunk 分别计', (tester) async {
      final post = _longPost();
      final plan = PostRenderPrep.planFor(post, topicId: 1);
      expect(plan.kind, PostRenderKind.long);
      expect(plan.unitCount, greaterThan(2));

      final warmed = _warmUnitsOf(plan);
      expect(warmed.map((u) => u.chunkIndex), [
        for (var i = 0; i < plan.unitCount; i++) i,
      ]);
      // 夹具自检:有的块带图、有的块不带,且带图块的偏移非 0
      expect(warmed.where((u) => u.totalImagesInPost > 0), isNotEmpty);
      expect(warmed.where((u) => u.totalImagesInPost == 0), isNotEmpty);
      expect(warmed.where((u) => u.imageIndexOffset > 0), isNotEmpty);

      for (var ci = 0; ci < plan.unitCount; ci++) {
        await tester.pumpWidget(_host(prefs, _chunkSegment(post, plan, ci)));
        final mounted = _mountedRender(tester);
        expect(
          identical(mounted.parsedNodes, warmed[ci].nodes),
          isTrue,
          reason: 'chunk $ci',
        );
        expect(
          countImageRuns(mounted.parsedNodes!),
          warmed[ci].totalImagesInPost,
          reason: 'chunk $ci',
        );
        expect(mounted.imageIndexOffset, warmed[ci].imageIndexOffset);
        expect(mounted.footnotesHtml, warmed[ci].footnotesHtml);
        expect(mounted.chunkIndex, ci);
      }
    });

    testWidgets('系统帖:超过分块阈值也不判成长帖,不预热,正文不按帖子样式挂载', (tester) async {
      final post = _systemPost();
      final plan = PostRenderPrep.planFor(post, topicId: 1);
      expect(plan.kind, PostRenderKind.system);
      expect(plan.unitCount, 0);
      expect(plan.longData, isNull);
      expect(_warmUnitsOf(plan), isEmpty);
      // 预热连解析都不做(系统帖备注挂载时才解析,样式也不同)
      expect(RenderParseCache.hasShortPost(post), isFalse);

      await tester.pumpWidget(_host(prefs, PostItem(post: post, topicId: 1)));
      expect(find.byType(SmallActionItem), findsOneWidget);
      // 唯一的 FluxdoRender 是备注(compact),内容单位同样经 PostRenderPrep
      final mounted = _mountedRender(tester);
      expect(mounted.compact, isTrue);
      expect(
        identical(mounted.parsedNodes, PostRenderPrep.shortUnit(post).nodes),
        isTrue,
      );
    });
  });

  group('端到端:经生产预热器热过之后挂载,段落 flatten 全部命中', () {
    /// 先挂一楼普通帖让挂载环境探针收敛(生产里首屏挂载即收敛)
    Future<void> convergeProbe(WidgetTester tester) async {
      await tester.pumpWidget(
        _host(prefs, PostItem(post: _shortPost(), topicId: 1)),
      );
      expect(ParagraphWarmupProbe.snapshot(), isNotNull);
    }

    void warmAll(WidgetTester tester, PostRenderPlan plan) {
      final context = tester.element(find.byType(Scaffold));
      final cursor = PostWarmCursor();
      final budget = WarmBudget(1 << 40, () => 0);
      for (var step = 0; step < 1000; step++) {
        final outcome = PostRenderPrep.warmOneUnit(
          plan,
          cursor,
          budget,
          paragraphWarmer: () => PostRenderPrep.probeParagraphWarmer(context),
        );
        expect(outcome, isNot(PostWarmOutcome.probeMissing));
        if (outcome == PostWarmOutcome.done) return;
      }
      fail('预热没有收敛');
    }

    testWidgets('带图短帖', (tester) async {
      await convergeProbe(tester);
      final post = _imagePost();
      warmAll(tester, PostRenderPrep.planFor(post, topicId: 1));

      final misses = FlattenCache.misses;
      await tester.pumpWidget(_host(prefs, PostItem(post: post, topicId: 1)));
      expect(FlattenCache.misses - misses, 0);
    });

    testWidgets('长帖各 chunk', (tester) async {
      await convergeProbe(tester);
      final post = _longPost();
      final plan = PostRenderPrep.planFor(post, topicId: 1);
      warmAll(tester, plan);

      for (var ci = 0; ci < plan.unitCount; ci++) {
        final misses = FlattenCache.misses;
        await tester.pumpWidget(_host(prefs, _chunkSegment(post, plan, ci)));
        expect(FlattenCache.misses - misses, 0, reason: 'chunk $ci');
      }
    });

    testWidgets('对照:图片数传 0(cc90e99d 之前)带图楼层必然 miss', (tester) async {
      await convergeProbe(tester);
      final post = _imagePost();
      final unit = PostRenderPrep.planFor(post, topicId: 1).unitAt(0);
      ParagraphWarmup.warmParagraphs(
        nodes: unit.nodes,
        ctx: ParagraphWarmupProbe.snapshot()!,
        context: tester.element(find.byType(Scaffold)),
        totalImagesInPost: 0,
        budgetMicros: 1 << 40,
      );

      final misses = FlattenCache.misses;
      await tester.pumpWidget(_host(prefs, PostItem(post: post, topicId: 1)));
      expect(FlattenCache.misses - misses, greaterThan(0));
    });
  });

  group('warmOneUnit', () {
    UnitParagraphWarmer? never() => fail('解析阶段不该取段落预热器');

    test('解析一步一件:短帖整帖一步,长帖逐块一步,之后才轮到段落', () {
      final short = PostRenderPrep.planFor(_shortPost());
      final cursor = PostWarmCursor();
      final budget = WarmBudget(1 << 40, () => 0);
      expect(
        PostRenderPrep.warmOneUnit(
          short,
          cursor,
          budget,
          paragraphWarmer: never,
        ),
        PostWarmOutcome.parsedPost,
      );
      expect(RenderParseCache.hasShortPost(short.post), isTrue);

      final long = PostRenderPrep.planFor(_longPost());
      for (var i = 0; i < long.unitCount; i++) {
        expect(
          PostRenderPrep.warmOneUnit(
            long,
            cursor,
            budget,
            paragraphWarmer: never,
          ),
          PostWarmOutcome.parsedChunk,
        );
      }
      expect(long.longData!.parseData.fullyParsed, isTrue);
    });

    test('探针未收敛:跳过段落(楼层前移)', () {
      final plan = PostRenderPrep.planFor(_shortPost());
      RenderParseCache.shortPost(plan.post);
      expect(
        PostRenderPrep.warmOneUnit(
          plan,
          PostWarmCursor(),
          WarmBudget(1 << 40, () => 0),
          paragraphWarmer: () => null,
        ),
        PostWarmOutcome.probeMissing,
      );
    });

    test('预算用尽:位置记在游标里,下一步原位续', () {
      final plan = PostRenderPrep.planFor(_longPost());
      plan.longData!.parseData.ensureParsedThrough(plan.unitCount - 1);
      var now = 0;
      final calls = <(int, int)>[];
      // 每次只热 2 个节点、耗 3ms
      int warmer(
        PostRenderUnit unit, {
        required int startIndex,
        required int budgetMicros,
      }) {
        calls.add((unit.chunkIndex, startIndex));
        now += 3000;
        final next = startIndex + 2;
        return next >= unit.nodes.length ? -1 : next;
      }

      final cursor = PostWarmCursor();
      // 4ms 预算:热完 2 个节点即返回,位置留在游标
      var outcome = PostRenderPrep.warmOneUnit(
        plan,
        cursor,
        WarmBudget(4000, () => now),
        paragraphWarmer: () => warmer,
      );
      expect(outcome, PostWarmOutcome.warmedParagraphs);
      expect((cursor.unit, cursor.node), (0, 2));

      // 进来时预算已耗尽:什么也不做,原位待续
      final spent = WarmBudget(1000, () => now);
      now += 1000;
      outcome = PostRenderPrep.warmOneUnit(
        plan,
        cursor,
        spent,
        paragraphWarmer: () => warmer,
      );
      expect(outcome, PostWarmOutcome.outOfBudget);
      expect((cursor.unit, cursor.node), (0, 2));

      // 下一步从同一位置续
      PostRenderPrep.warmOneUnit(
        plan,
        cursor,
        WarmBudget(4000, () => now),
        paragraphWarmer: () => warmer,
      );
      expect(calls, [(0, 0), (0, 2)]);
    });
  });

  group('PostRenderPlans', () {
    test('实例未变直接复用;只换实例(点赞)复用解析产物;内容变了重建', () {
      final plans = PostRenderPlans();
      final post = _longPost();
      final first = plans.planFor(post);
      expect(identical(plans.planFor(post), first), isTrue);

      final liked = post.copyWith(likeCount: 3);
      final refreshed = plans.planFor(liked);
      expect(identical(refreshed.post, liked), isTrue);
      expect(identical(refreshed.longData, first.longData), isTrue);

      final edited = post.copyWith(cooked: '<p>改短了</p>');
      final rebuilt = plans.planFor(edited);
      expect(rebuilt.kind, PostRenderKind.short);
      expect(rebuilt.longData, isNull);

      plans.retainOnly({});
      expect(plans[post.id], isNull);
    });
  });
}
