import 'package:flutter/widgets.dart';
import 'package:fluxdo_render/fluxdo_render.dart';

import '../../../models/topic.dart';
import '../small_action_item.dart' show PostTypes;
import 'render_parse_cache.dart';
import 'segmented_long_post.dart';

/// 帖子渲染准备:楼层「怎么渲染、每个 FluxdoRender 吃什么」的唯一出处。
///
/// 滚动顺滑靠预热:楼层进视口前先把解析、flatten、排版做进全局缓存
/// ([RenderParseCache] / FlattenCache / ParagraphLayoutCache),挂载时
/// FluxdoRender 按自己算出的 key 查表复用。预热侧必须重建与挂载侧
/// **完全相同**的 key 输入,否则预热静默白做、滚动掉帧回来 —— 这件事
/// 出过两次(cc90e99d 预热传 totalImagesInPost 0、挂载侧 countImageRuns;
/// 8a01bdce 短帖实例缓存签名漏字段)。所以下面几件事只在这里算一次:
///
/// - 内容签名([signatureOf],即 [RenderParseCache.signatureOf]);
/// - 渲染形态判定:系统帖 / 短帖 / 长帖([planFor]);
/// - 每个挂载单位的 nodes 与图片数([PostRenderPlan.unitAt]、[shortUnit]);
/// - 预热一个单位([warmOneUnit])。
///
/// PostItem、长帖 chunk 段、系统帖备注、TOC 提取、预热调度都经这里取,
/// FluxdoRender 本身的用法不变(仍由各挂载 widget 构造)。
abstract final class PostRenderPrep {
  /// 内容签名:cooked + mention 状态 + 链接点击数(预处理的全部输入)。
  /// 唯一定义在 [RenderParseCache.signatureOf](缓存条目据此失效),
  /// 列表级的计划复用([PostRenderPlans])也用它。
  static int signatureOf(Post post) => RenderParseCache.signatureOf(post);

  /// 系统操作帖:走 SmallActionItem,不走正文渲染、不分长帖、不预热。
  ///
  /// 只按 post_type 判断会漏:discourse-assign 在 assigns_public 关闭时
  /// 把指定/取消指定帖建成 whisper(post_type=4)而不是 small_action(3);
  /// action_code 才是 Discourse 标记「系统生成的操作记录帖」的字段,
  /// 普通用户帖永远没有。这类帖 cooked 里常塞几十个 emoji <img>,很容易
  /// 超过长帖分块阈值 —— 判成长帖就会被当成能点赞/回复的普通帖渲染出来,
  /// 所以系统帖判定先于长短判定。
  static bool isSystemPost(Post post) =>
      post.postType == PostTypes.smallAction ||
      (post.actionCode?.isNotEmpty ?? false);

  /// 楼层的渲染计划:形态判定 + 长帖分块数据(切分 eager、单块解析 lazy,
  /// 解析状态在 [RenderParseCache] 全局 LRU)。
  ///
  /// [topicId] / [onQuoteImage] 只进长帖 callbacks(链接点击追踪、图片引用
  /// 菜单),不影响形态与缓存 key。
  static PostRenderPlan planFor(
    Post post, {
    int? topicId,
    void Function(String quote, Post post)? onQuoteImage,
  }) {
    final signature = signatureOf(post);
    if (isSystemPost(post)) {
      return PostRenderPlan._(
        post: post,
        signature: signature,
        kind: PostRenderKind.system,
      );
    }
    final longData = NewEngineLongPostData.tryBuild(
      post,
      topicId: topicId,
      onQuoteImage: onQuoteImage,
    );
    return PostRenderPlan._(
      post: post,
      signature: signature,
      kind: longData == null ? PostRenderKind.short : PostRenderKind.long,
      longData: longData,
    );
  }

  /// 整帖一个 FluxdoRender 的挂载单位(PostItem 正文、系统帖备注、短帖预热)。
  /// 解析产物走 [RenderParseCache] 全局 LRU(命中即复用,触碰 LRU 顺序)。
  static PostRenderUnit shortUnit(Post post) {
    final parsed = RenderParseCache.shortPost(post);
    return PostRenderUnit(cookedHtml: parsed.preprocessed, nodes: parsed.nodes);
  }

  /// 对 [plan] 做一个原子单位的预热,不超 [budget]:
  ///
  /// 1. 解析阶段:短帖未解析 → 解析整帖(1~5ms);长帖有未解析块 → 解析
  ///    下一块(1~3ms)。一步只做一件,做完即返回;
  /// 2. 段落阶段:按 [cursor] 逐单位(长帖逐 chunk)预热段落 flatten +
  ///    排版,预算用尽就把位置记在 [cursor] 里,下一步原位续。
  ///
  /// [paragraphWarmer] 在解析完成后取一次;返回 null = 挂载环境探针还没
  /// 收敛(首屏还没有直绘段落挂载),段落只能跳过。生产用
  /// [probeParagraphWarmer]。
  ///
  /// 已解析的判定只探测([RenderParseCache.hasShortPost] /
  /// [LongPostParseData.fullyParsed]),不触碰 LRU、不付解析成本。
  static PostWarmOutcome warmOneUnit(
    PostRenderPlan plan,
    PostWarmCursor cursor,
    WarmBudget budget, {
    required UnitParagraphWarmer? Function() paragraphWarmer,
  }) {
    if (plan.kind == PostRenderKind.system) return PostWarmOutcome.done;
    final parseData = plan.longData?.parseData;
    if (parseData != null) {
      if (!parseData.fullyParsed) {
        parseData.warmUpOneChunk();
        return PostWarmOutcome.parsedChunk;
      }
    } else if (!RenderParseCache.hasShortPost(plan.post)) {
      RenderParseCache.shortPost(plan.post);
      return PostWarmOutcome.parsedPost;
    }
    final warm = paragraphWarmer();
    if (warm == null) return PostWarmOutcome.probeMissing;
    final unitCount = plan.unitCount;
    while (cursor.unit < unitCount) {
      final remaining = budget.remainingMicros;
      // 预算用尽:位置留在 cursor,下一步从这里续
      if (remaining <= 0) return PostWarmOutcome.outOfBudget;
      final next = warm(
        plan.unitAt(cursor.unit),
        startIndex: cursor.node,
        budgetMicros: remaining,
      );
      if (next != -1) {
        cursor.node = next;
        return PostWarmOutcome.warmedParagraphs;
      }
      cursor
        ..unit += 1
        ..node = 0;
    }
    return PostWarmOutcome.done;
  }

  /// 生产用段落预热器:探针众数快照提供 (baseStyle, theme, flattener, env,
  /// 宽度) —— 由真实挂载登记,与挂载 100% 同源(见 ParagraphWarmupProbe);
  /// 其余 key 输入(inlines 身份、totalImagesInPost)取自挂载单位本身,
  /// 与 FluxdoRender 内部同式。探针未收敛返回 null。
  ///
  /// handler 不传:预热产物按 (inlines 身份, style, theme, 图片数) 进全局
  /// 缓存,handler 不进 key;内容同身份 → 命中的是 span/排版,recognizer
  /// 行为经 mount 桥现取活 context,共享 static handler + 无 post 语境的
  /// 兜底即可。[context] 仅供 flatten 同步读主题色。
  static UnitParagraphWarmer? probeParagraphWarmer(BuildContext context) {
    final snapshot = ParagraphWarmupProbe.snapshot();
    if (snapshot == null) return null;
    return (unit, {required startIndex, required budgetMicros}) =>
        ParagraphWarmup.warmParagraphs(
          nodes: unit.nodes,
          ctx: snapshot,
          context: context,
          totalImagesInPost: unit.totalImagesInPost,
          startIndex: startIndex,
          budgetMicros: budgetMicros,
        );
  }
}

/// 帖子正文的渲染形态
enum PostRenderKind {
  /// 系统操作帖:SmallActionItem,不预热
  system,

  /// 短帖:整帖一个 FluxdoRender(PostItem)
  short,

  /// 长帖:header + 每 chunk 一个 FluxdoRender + footer,sliver 分段虚拟化
  long,
}

/// 一个挂载单位 = 一个 FluxdoRender 的内容输入:短帖整帖一个,长帖每
/// chunk 一个。挂载 widget 把这些原样交给 FluxdoRender,预热只从这里取
/// nodes 与图片数 —— 两侧 key 输入同源。
@immutable
class PostRenderUnit {
  const PostRenderUnit({
    required this.cookedHtml,
    required this.nodes,
    this.chunkIndex = 0,
    this.imageIndexOffset = 0,
    this.footnotesHtml,
    this.trimTopMargin = false,
    this.trimBottomMargin = false,
  });

  /// FluxdoRender.cookedHtml(短帖 = 预处理后整帖,长帖 = chunk html)
  final String cookedHtml;

  /// FluxdoRender.parsedNodes(全局缓存里的同一实例 —— 段落缓存 key
  /// 按 inlines 身份比对)
  final List<BlockNode> nodes;

  /// chunk 文档序号(短帖 0)
  final int chunkIndex;

  /// 图片 indexInPost 起始偏移(之前所有 chunk 的图片数;短帖 0)
  final int imageIndexOffset;

  /// 整帖脚注区(chunk 不含帖尾脚注区,需单独传;短帖 null)
  final String? footnotesHtml;

  /// 被分块切断的单段落接缝:裁掉接缝侧外边距
  final bool trimTopMargin;
  final bool trimBottomMargin;

  /// 本单位进段落缓存 key 的图片数,与 FluxdoRender 挂载时同式:
  /// `countImageRuns(parsedNodes)` —— 按**这个 FluxdoRender 自己的 nodes**
  /// 计,长帖按 chunk 分别计(不是整帖图片数,也不是 0)。
  int get totalImagesInPost => countImageRuns(nodes);
}

/// 楼层的渲染计划:形态 + 长帖分块数据,挂载单位按需从这里取。
class PostRenderPlan {
  PostRenderPlan._({
    required this.post,
    required this.signature,
    required this.kind,
    this.longData,
  });

  /// 计划所属的帖子(签名复用时刷新为最新实例)
  final Post post;

  /// 建计划时的内容签名([PostRenderPrep.signatureOf])
  final int signature;

  final PostRenderKind kind;

  /// 长帖分块数据(含 callbacks);仅 [PostRenderKind.long] 非 null
  final NewEngineLongPostData? longData;

  bool get isLong => kind == PostRenderKind.long;

  /// 长帖的 chunk 列表;其余形态为空
  List<HtmlChunk> get chunks => longData?.chunks ?? const <HtmlChunk>[];

  /// 挂载单位数:系统帖 0(不走正文渲染),短帖 1,长帖 = chunk 数
  int get unitCount => switch (kind) {
    PostRenderKind.system => 0,
    PostRenderKind.short => 1,
    PostRenderKind.long => longData!.chunks.length,
  };

  /// 第 [index] 个挂载单位。长帖未解析的 chunk 在这里解析(顺序补齐前缀,
  /// 单块只解析一次);短帖走 [PostRenderPrep.shortUnit]。
  PostRenderUnit unitAt(int index) {
    final long = longData;
    if (long == null) {
      assert(kind == PostRenderKind.short && index == 0);
      return PostRenderPrep.shortUnit(post);
    }
    final chunk = long.chunks[index];
    return PostRenderUnit(
      cookedHtml: chunk.html,
      nodes: long.parsedChunkAt(index),
      chunkIndex: index,
      imageIndexOffset: long.imageOffsetAt(index),
      footnotesHtml: long.footnotesHtml,
      trimTopMargin: chunk.joinsPrevious,
      trimBottomMargin: chunk.joinsNext,
    );
  }

  /// 换帖子实例、保留解析产物(签名未变时)
  PostRenderPlan _withPost(Post post) => PostRenderPlan._(
    post: post,
    signature: signature,
    kind: kind,
    longData: longData,
  );
}

/// 列表级的渲染计划表(post.id → plan),帖子列表与预热共用同一份。
///
/// 长帖的 [NewEngineLongPostData] 持有挂载中 chunk 用的那份解析状态,
/// 预热必须热到**同一个实例**上:全局 LRU 淘汰后若各自重建,预热就落在
/// 挂载用不到的对象里。
class PostRenderPlans {
  final Map<int, PostRenderPlan> _plans = {};

  /// 已有计划(不新建);预热据此找挂载用的那份
  PostRenderPlan? operator [](int postId) => _plans[postId];

  /// 取/建 [post] 的计划:
  /// - post 实例未变 → 原样复用;
  /// - 实例变了但内容签名与系统帖判定都没变(message bus 单帖更新点赞数
  ///   等 copyWith)→ 复用解析产物,只刷新 post 引用。否则每次点赞推送
  ///   都会重新预处理 + 切 chunk + 丢掉全部已解析 chunk,已挂载的 chunk
  ///   被迫同步重新解析,一次几十 ms;
  /// - 否则重建。
  PostRenderPlan planFor(
    Post post, {
    int? topicId,
    void Function(String quote, Post post)? onQuoteImage,
  }) {
    final cached = _plans[post.id];
    if (cached != null && identical(cached.post, post)) return cached;
    if (cached != null &&
        cached.signature == PostRenderPrep.signatureOf(post) &&
        (cached.kind == PostRenderKind.system) ==
            PostRenderPrep.isSystemPost(post)) {
      return _plans[post.id] = cached._withPost(post);
    }
    return _plans[post.id] = PostRenderPrep.planFor(
      post,
      topicId: topicId,
      onQuoteImage: onQuoteImage,
    );
  }

  /// 只保留 [postIds] 里的楼层(离开帖子流的楼层不再持有解析状态)
  void retainOnly(Set<int> postIds) {
    _plans.removeWhere((postId, _) => !postIds.contains(postId));
  }
}

/// 段落预热一步:对 [unit] 从 [startIndex] 起预热,超 [budgetMicros] 即停。
/// 返回下一个待处理下标;全部完成返回 -1。
typedef UnitParagraphWarmer =
    int Function(
      PostRenderUnit unit, {
      required int startIndex,
      required int budgetMicros,
    });

/// [PostRenderPrep.warmOneUnit] 的结果
enum PostWarmOutcome {
  /// 解析了一帖短帖(本步到此为止,楼层不变)
  parsedPost,

  /// 解析了长帖的一块(本步到此为止,楼层不变)
  parsedChunk,

  /// 预热了一片段落、该楼层还有剩余(位置记在游标里)
  warmedParagraphs,

  /// 预算已用尽,什么也没做;下一步原位续
  outOfBudget,

  /// 探针未收敛,段落只能跳过;楼层前移
  probeMissing,

  /// 该楼层已无事可做(系统帖 / 全部热完 / 楼层不在列表里);楼层前移
  done;

  /// 本步留在该楼层(下一步原位续)
  bool get staysOnPost =>
      this == parsedPost ||
      this == parsedChunk ||
      this == warmedParagraphs ||
      this == outOfBudget;
}

/// 一个楼层内的预热位置:第几个挂载单位的第几个顶层节点
class PostWarmCursor {
  int unit = 0;
  int node = 0;

  void reset() {
    unit = 0;
    node = 0;
  }
}

/// 一步的时间预算,按注入的单调时钟计(测试可用假时钟)
class WarmBudget {
  WarmBudget(this.limitMicros, this._nowMicros) : _startMicros = _nowMicros();

  final int limitMicros;
  final int Function() _nowMicros;
  final int _startMicros;

  int get elapsedMicros => _nowMicros() - _startMicros;
  int get remainingMicros => limitMicros - elapsedMicros;
}
