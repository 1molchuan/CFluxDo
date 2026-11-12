import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fluxdo_render/fluxdo_render.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import '../../../l10n/s.dart';
import '../../../models/topic.dart';
import '../../../providers/preferences_provider.dart';
import '../../../providers/topic_session_provider.dart';
import '../../../utils/blocked_user_filter.dart';
import '../../../utils/frame_jank_monitor.dart';
import '../../common/perf_span_box.dart';
import '../../../services/toast_service.dart';
import '../../../utils/fluxdo_render_callbacks.dart';
import '../post_boost/boost_actions.dart';
import '../post_boost/boost_danmaku.dart';
import '../post_signature_block.dart';
import 'post_render_prep.dart';
import 'quote_selection_helper.dart';
import 'render_parse_cache.dart';
import 'widgets/post_footer_section/post_footer_section.dart';
import 'widgets/post_header_section.dart';
import 'widgets/post_segment_frame.dart';
import 'widgets/vscode_post_source.dart';
import '../../../theme/mojian_theme.dart';

/// 新引擎长帖分段数据(chunk 切分 eager,单 chunk 解析 lazy)。
/// - 解析状态([LongPostParseData]:切分结果 + 逐 chunk 解析记忆化)存
///   [RenderParseCache] 全局 LRU —— sliver item 回收/重进话题不重付
///   preprocess + DOM 解析(对齐 legacy HtmlParseService 的全局缓存层)。
/// - [callbacks] 是持 post/topicId 的闭包,每次构建自建,不进全局缓存。
class NewEngineLongPostData {
  final LongPostParseData parseData;
  late final FluxdoRenderCallbacks callbacks;

  NewEngineLongPostData._(this.parseData);

  List<HtmlChunk> get chunks => parseData.chunks;
  String? get footnotesHtml => parseData.footnotesHtml;

  /// 第 [index] 块的解析结果(未解析时顺序补齐前缀并缓存)。
  List<BlockNode> parsedChunkAt(int index) => parseData.parsedChunkAt(index);

  /// 第 [index] 块的图片 indexInPost 起始偏移。
  int imageOffsetAt(int index) => parseData.imageOffsetAt(index);

  /// 长帖且可切多 chunk 时返回数据;否则 null(短帖走整段 PostItem)。
  ///
  /// 只做长短判定,不管系统帖:调用方一律经 [PostRenderPrep.planFor]
  /// (系统帖判定在前),不要直接调这里。
  static NewEngineLongPostData? tryBuild(
    Post post, {
    // 链接点击追踪 + 图片引用菜单引用上下文(透传给 forPost → imageContentBuilder
    // / linkHandler)。NewEngineLongPostData 本身无需新增字段(callbacks 闭包已捕获)。
    int? topicId,
    void Function(String quote, Post post)? onQuoteImage,
  }) {
    final parseData = _parseDataFor(post);
    if (parseData == null) return null;

    final data = NewEngineLongPostData._(parseData);
    data.callbacks = FluxdoRenderCallbacks.forPost(
      post: post,
      topicId: topicId,
      onQuoteImage: onQuoteImage,
      preprocessedCooked: parseData.preprocessed,
      // 画廊惰性:首次点图才收集(触发剩余 chunk 解析),构建时零解析成本
      lightboxImageRunsProvider: parseData.collectAllLightboxImageRuns,
    );
    return data;
  }

  static LongPostParseData? _parseDataFor(Post post) =>
      RenderParseCache.longPost(post, () {
        final preprocessed = FluxdoRenderCallbacks.preprocessCookedForRender(
          post,
        );
        if (preprocessed.length <= HtmlChunker.chunkThreshold) return null;
        final chunks = _splitLargeBlockquotes(HtmlChunker.chunk(preprocessed));
        if (chunks.length <= 1) return null;
        return LongPostParseData(
          preprocessed: preprocessed,
          chunks: chunks,
          footnotesHtml: _extractFootnotesSection(preprocessed),
        );
      });

  // 大引用块拆分阈值:内部块数或字符数超过即拆(都不超 → 小引用块不拆,零开销)。
  static const _bqSplitMinBlocks = 6;
  static const _bqSplitMinChars = 1500;

  /// 把 chunk 列表里的「大 blockquote」装饰下放拆成多片,其余原样透传,最后重编 index。
  static List<HtmlChunk> _splitLargeBlockquotes(List<HtmlChunk> chunks) {
    final expanded = <HtmlChunk>[];
    for (final c in chunks) {
      if (c.type == HtmlChunkType.blockquote) {
        expanded.addAll(_splitBlockquoteChunk(c.html));
      } else {
        expanded.add(c);
      }
    }
    return [
      for (var i = 0; i < expanded.length; i++)
        HtmlChunk(
          html: expanded[i].html,
          type: expanded[i].type,
          index: i,
          joinsPrevious: expanded[i].joinsPrevious,
          joinsNext: expanded[i].joinsNext,
        ),
    ];
  }

  /// 把一个 `<blockquote>` chunk 拆成多片:每片 re-wrap 成
  /// `<blockquote ...原属性 data-fxd-pos="first|mid|last">子片</blockquote>`,
  /// 子包按 pos 渲染连续装饰。小引用块不拆。
  ///
  /// callout(`[!type]`):**不可折叠**的大 callout 也拆 —— 首片保留 `[!type]`
  /// 标记(子包走文本识别出标题头),中/尾片打 `data-fxd-callout` 属性(只 kind
  /// + body)。可折叠 callout 不拆(折叠态本就懒构建)。
  static List<HtmlChunk> _splitBlockquoteChunk(String html) {
    HtmlChunk whole() =>
        HtmlChunk(html: html, type: HtmlChunkType.blockquote, index: 0);
    final frag = html_parser.parseFragment(html);
    final root = frag.children.isNotEmpty ? frag.children.first : null;
    if (root == null || root.localName?.toLowerCase() != 'blockquote') {
      return [whole()];
    }

    // 太小不拆(零开销)。
    final smallByBlocks = root.children.length <= _bqSplitMinBlocks;
    final smallByChars = root.text.length <= _bqSplitMinChars;
    if (smallByBlocks && smallByChars) return [whole()];

    final sub = HtmlChunker.chunk(root.innerHtml);
    if (sub.length <= 1) return [whole()];

    final attrs = _attrsString(root); // 保留原 class 等属性

    // callout 识别:首行 [!type]([+-] = 可折叠 → 不拆)。
    final callout = RegExp(r'^\[!([^\]]+)\]([+-])?')
        .firstMatch(root.text.trimLeft());
    if (callout != null) {
      if (callout.group(2) != null) return [whole()]; // 可折叠不拆
      final kind = callout.group(1)!.trim().toLowerCase();
      return [
        for (var i = 0; i < sub.length; i++)
          HtmlChunk(
            // 首片保留 [!type] 标记(在 sub[0] 内)→ 子包文本识别出标题头;
            // 中/尾片打属性 → 子包属性识别(只 kind + body,无头)。
            html: i == 0
                ? '<blockquote$attrs data-fxd-pos="${_pos(i, sub.length)}">'
                      '${sub[i].html}</blockquote>'
                : '<blockquote$attrs data-fxd-callout="$kind" '
                      'data-fxd-pos="${_pos(i, sub.length)}">'
                      '${sub[i].html}</blockquote>',
            type: HtmlChunkType.blockquote,
            index: i,
          ),
      ];
    }

    // 普通 blockquote。
    return [
      for (var i = 0; i < sub.length; i++)
        HtmlChunk(
          html:
              '<blockquote$attrs data-fxd-pos="${_pos(i, sub.length)}">'
              '${sub[i].html}</blockquote>',
          type: HtmlChunkType.blockquote,
          index: i,
        ),
    ];
  }

  static String _pos(int i, int n) =>
      i == 0 ? 'first' : (i == n - 1 ? 'last' : 'mid');

  /// 序列化元素原属性为 ` k="v"` 串(排除 data-fxd-pos,避免重复)。
  static String _attrsString(dom.Element el) {
    final buf = StringBuffer();
    el.attributes.forEach((k, v) {
      final key = k.toString();
      if (key == 'data-fxd-pos') return;
      buf.write(' $key="$v"');
    });
    return buf.toString();
  }

  /// 抽出整帖脚注区 `<section class="footnotes">…</section>`(无则 null)。
  static String? _extractFootnotesSection(String html) {
    final m = RegExp(
      r'<section[^>]*class="[^"]*footnotes[^"]*"[^>]*>[\s\S]*?</section>',
      caseSensitive: false,
    ).firstMatch(html);
    return m?.group(0);
  }
}

/// 新引擎长帖的单个 chunk 段:用 [FluxdoRender] 渲染一个挂载单位
/// ([PostRenderPlan.unitAt],与预热同源)。自带自研选区(chunk 内),
/// 图片/脚注靠单位里的 imageIndexOffset / footnotesHtml + 共享 [callbacks]
/// 对齐整帖。
/// 首 chunk(chunkIndex == 0)在弹幕模式下叠加 [BoostDanmaku]:长帖的
/// header/chunk/footer 是不同 sliver item,弹幕层只能落在正文段上。
class NewEngineChunkSegment extends ConsumerWidget {
  final Post post;
  final int topicId;

  /// 已叠加楼层起点与 chunk 相对偏移的绝对行号。
  final int sourceFirstLine;
  final bool sourceLastUnit;
  final bool selected;
  final bool highlight;

  /// 本 chunk 的挂载单位:html、解析好的 nodes、图片偏移、脚注区、接缝裁边
  final PostRenderUnit unit;
  final FluxdoRenderCallbacks callbacks;
  final void Function(String plainText, Post post)? onQuoteSelection;

  /// 高亮指定用户名的 boost(从 boost 通知跳转时使用)
  final String? highlightBoostUsername;

  /// 话题标题(boost 作者卡片预填私信标题用)
  final String? topicTitle;

  const NewEngineChunkSegment({
    super.key,
    required this.post,
    required this.topicId,
    this.sourceFirstLine = 1,
    this.sourceLastUnit = true,
    required this.selected,
    required this.highlight,
    required this.unit,
    required this.callbacks,
    required this.onQuoteSelection,
    this.highlightBoostUsername,
    this.topicTitle,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final chunkIndex = unit.chunkIndex;
    FrameJankMonitor.noteBuild(
      'chk#${post.postNumber}:$chunkIndex/'
      '${(unit.cookedHtml.length / 1000).toStringAsFixed(1)}k',
    );
    Widget content = FluxdoRender(
      cookedHtml: unit.cookedHtml,
      parsedNodes: unit.nodes,
      // 正文字号注入 contentFontScale(与 PostItem 短帖路径一致):
      // 不传时 NodeFactory 回退 theme.bodyMedium,长帖 chunk 的字号设置失效。
      baseTextStyle: MojianTheme.postBodyStyle(
        theme,
        ref.watch(preferencesProvider).contentFontScale,
      ),
      imageIndexOffset: unit.imageIndexOffset,
      footnotesHtml: unit.footnotesHtml,
      // 同 post 各 chunk 共享一个选区作用域 → 选区可跨 chunk。
      selectionScopeId: post.id,
      // chunk 文档序号 → 跨 chunk 选区按 (chunkIndex, docOrder) 逻辑序排序。
      chunkIndex: chunkIndex,
      // 被分块切断的单段落接缝:裁掉接缝侧外边距 → 与连续渲染无缝拼接。
      trimTopMargin: unit.trimTopMargin,
      trimBottomMargin: unit.trimBottomMargin,
      linkHandler: callbacks.linkHandler,
      emojiImageBuilder: callbacks.emojiImageBuilder,
      mentionTapHandler: callbacks.mentionTapHandler,
      imageContentBuilder: callbacks.imageContentBuilder,
      codeBlockHighlighter: callbacks.codeBlockHighlighter,
      codeBlockBuilder: callbacks.codeBlockBuilder,
      quoteAvatarBuilder: callbacks.quoteAvatarBuilder,
      footnoteTapHandler: callbacks.footnoteTapHandler,
      lazyVideoBuilder: callbacks.lazyVideoBuilder,
      iframeBuilder: callbacks.iframeBuilder,
      localDateBuilder: callbacks.localDateBuilder,
      mathBlockBuilder: callbacks.mathBlockBuilder,
      mathInlineBuilder: callbacks.mathInlineBuilder,
      oneboxBuilder: callbacks.oneboxBuilder,
      imageGridBuilder: callbacks.imageGridBuilder,
      policyBuilder: callbacks.policyBuilder,
      pollBuilder: callbacks.pollBuilder,
      chatTranscriptBuilder: callbacks.chatTranscriptBuilder,
      svgBuilder: callbacks.svgBuilder,
      videoBuilder: callbacks.videoBuilder,
      audioBuilder: callbacks.audioBuilder,
      onDownloadAttachment: callbacks.onDownloadAttachment,
      // 自研选区恒开(外层系统 SelectionArea 已拆):未登录时
      // onQuoteRequest 为 null,toolbar 自动降级只留「复制/复制引用」。
      selectionEnabled: true,
      onQuoteRequest: onQuoteSelection == null
          ? null
          : (plainText) => onQuoteSelection!(plainText, post),
      onCopyQuoteRequest: (plainText) =>
          QuoteSelectionHelper.copyQuoteToClipboard(
            selectedText: plainText,
            post: post,
            topicId: topicId,
          ),
      onCopyToast: () =>
          ToastService.showSuccess(context.l10n.common_copiedToClipboard),
    );

    if (VscodePostSource.enabled(context)) {
      final richText = content;
      content = VscodePostSource(
        key: ValueKey('source-${post.id}-$chunkIndex'),
        post: post,
        topicId: topicId,
        topicTitle: topicTitle,
        onQuoteSelection: onQuoteSelection,
        document: VscodeSourceDocument.forHtml(unit.cookedHtml),
        firstLine: sourceFirstLine,
        firstUnit: chunkIndex == 0,
        lastUnit: sourceLastUnit,
        fontScale: ref.watch(preferencesProvider).contentFontScale,
        richTextBuilder: (_) => richText,
      );
    }

    // 首 chunk 弹幕层(与 PostItem 的短帖路径同一套开关判定)
    if (chunkIndex == 0) {
      final danmakuBoosts = _danmakuBoosts(ref);
      if (danmakuBoosts != null && danmakuBoosts.isNotEmpty) {
        final trackCount = danmakuBoosts.length <= 1
            ? 1
            : danmakuBoosts.length <= 4
            ? 2
            : 3;
        content = Stack(
          clipBehavior: Clip.none,
          children: [
            content,
            Positioned.fill(
              child: BoostDanmaku(
                visibilityKey: post.id,
                boosts: danmakuBoosts,
                maxTrackCount: trackCount,
                highlightUsername: highlightBoostUsername,
                onBoostTap: (boost, anchorRect) {
                  BoostActions.show(
                    context: context,
                    ref: ref,
                    post: post,
                    topicId: topicId,
                    boost: boost,
                    anchorRect: anchorRect,
                    topicTitle: topicTitle,
                  );
                },
              ),
            ),
          ],
        );
      }
    }

    // PerfSpanBox:单 chunk 子树的 layout/paint 账单(监控关闭零开销)
    return PerfSpanBox(
      label: 'chk#${post.postNumber}:$chunkIndex',
      child: PostSegmentFrame(
        post: post,
        selected: selected,
        highlight: highlight,
        showBottomBorder: false,
        child: Padding(
          padding: VscodePostSource.enabled(context)
              ? EdgeInsets.zero
              : const EdgeInsets.symmetric(horizontal: 16),
          child: content,
        ),
      ),
    );
  }

  /// 弹幕模式下首 chunk 要放的 boost;不放(偏好关/帖级关/无 boost)时
  /// 返回 null。watch 都带 select,与短帖路径同粒度。
  List<Boost>? _danmakuBoosts(WidgetRef ref) {
    final danmakuPref = ref.watch(
      preferencesProvider.select((p) => p.boostDanmaku),
    );
    if (!danmakuPref) return null;
    final danmakuOff = ref.watch(
      topicSessionProvider(topicId)
          .select((s) => s.danmakuOffPostIds.contains(post.id)),
    );
    if (danmakuOff) return null;
    final blockedUsernames = ref.watch(
      preferencesProvider.select((p) => p.normalizedBlockedUsernames),
    );
    return BlockedUserFilter.visibleBoosts(
      post.boosts ?? const <Boost>[],
      blockedUsernames,
    );
  }
}

class LongPostHeaderSegment extends ConsumerWidget {
  final Post post;
  final int topicId;
  final bool selected;
  final bool highlight;
  final bool isTopicOwner;
  final String? dateSeparatorLabel;
  final bool showDivider;
  final void Function(int postNumber)? onJumpToPost;

  /// 头像长按菜单「@用户」回调（null = 不可回复，菜单不显示该项）
  final void Function(String username)? onMentionUser;

  const LongPostHeaderSegment({
    super.key,
    required this.post,
    required this.topicId,
    required this.selected,
    required this.highlight,
    required this.isTopicOwner,
    required this.dateSeparatorLabel,
    required this.showDivider,
    required this.onJumpToPost,
    this.onMentionUser,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    FrameJankMonitor.noteBuild('hdr#${post.postNumber}');
    // 弹幕开关(与 PostItem 短帖路径同判定):全局偏好开 且 有可见 boost
    // 才显示 header 上的帖级 toggle;开关状态在会话层,三段共享。
    final danmakuPref = ref.watch(
      preferencesProvider.select((p) => p.boostDanmaku),
    );
    bool? danmakuActive;
    VoidCallback? onToggleDanmaku;
    if (danmakuPref) {
      final blockedUsernames = ref.watch(
        preferencesProvider.select((p) => p.normalizedBlockedUsernames),
      );
      final hasBoosts = BlockedUserFilter.visibleBoosts(
        post.boosts ?? const <Boost>[],
        blockedUsernames,
      ).isNotEmpty;
      if (hasBoosts) {
        final danmakuOff = ref.watch(
          topicSessionProvider(topicId)
              .select((s) => s.danmakuOffPostIds.contains(post.id)),
        );
        danmakuActive = !danmakuOff;
        onToggleDanmaku = () => ref
            .read(topicSessionProvider(topicId).notifier)
            .setDanmakuOff(post.id, !danmakuOff);
      }
    }
    return PostSegmentFrame(
      post: post,
      selected: selected,
      highlight: highlight,
      showTopDateSeparator: dateSeparatorLabel != null,
      topDateSeparatorLabel: dateSeparatorLabel,
      showDivider: showDivider,
      showBottomBorder: false,
      child: PostHeaderSection(
        post: post,
        topicId: topicId,
        isTopicOwner: isTopicOwner,
        showStamp: post.acceptedAnswer,
        padding: VscodePostSource.enabled(context)
            ? EdgeInsets.zero
            : const EdgeInsets.fromLTRB(16, 16, 16, 12),
        onJumpToPost: onJumpToPost,
        onMentionUser: onMentionUser,
        danmakuActive: danmakuActive,
        onToggleDanmaku: onToggleDanmaku,
      ),
    );
  }
}

class LongPostFooterSegment extends ConsumerWidget {
  final Post post;
  final int topicId;

  /// 话题分类 id,用于签名的 signatures_show_in_categories 门禁。
  final int? categoryId;
  final bool selected;
  final bool highlight;
  final bool topicHasAcceptedAnswer;
  final List<AcceptedAnswer> acceptedAnswers;
  final String? bottomDateSeparatorLabel;
  final void Function({String? initialContent})? onReply;
  final VoidCallback? onEdit;
  final VoidCallback? onShareAsImage;
  final void Function(int postId)? onRefreshPost;
  final void Function(int postNumber)? onJumpToPost;
  final void Function(int postId, bool accepted)? onSolutionChanged;
  final bool useReplyDialog;
  final String? topicTitle;
  final bool isPrivateMessageTopic;
  final bool isPmWithNonHumanUser;
  final VoidCallback? onShowPostDetail;
  final String? highlightBoostUsername;

  /// OP 帖专属插槽: 仅在 postNumber == 1 时透传给 PostFooterSection
  final Widget? opTopSlot;

  /// post-voting(问答)话题:footer 显示赞成/反对控件与评论区
  final bool isPostVotingTopic;

  /// 话题 closed/archived(问答投票禁投判定)
  final bool topicClosed;

  const LongPostFooterSegment({
    super.key,
    required this.post,
    required this.topicId,
    this.categoryId,
    required this.selected,
    required this.highlight,
    this.highlightBoostUsername,
    required this.topicHasAcceptedAnswer,
    this.acceptedAnswers = const [],
    required this.bottomDateSeparatorLabel,
    required this.onReply,
    required this.onEdit,
    required this.onShareAsImage,
    required this.onRefreshPost,
    required this.onJumpToPost,
    required this.onSolutionChanged,
    this.useReplyDialog = false,
    this.topicTitle,
    this.isPrivateMessageTopic = false,
    this.isPmWithNonHumanUser = false,
    this.onShowPostDetail,
    this.opTopSlot,
    this.isPostVotingTopic = false,
    this.topicClosed = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    FrameJankMonitor.noteBuild('ftr#${post.postNumber}');
    // 与首 chunk 弹幕层同判定:弹幕实际在显示时才隐藏 footer 的 boost
    // 气泡列表(danmakuActive 传给 PostFooterSection/_buildBoostArea)。
    final danmakuPref = ref.watch(
      preferencesProvider.select((p) => p.boostDanmaku),
    );
    bool? danmakuActive;
    if (danmakuPref) {
      final blockedUsernames = ref.watch(
        preferencesProvider.select((p) => p.normalizedBlockedUsernames),
      );
      final hasBoosts = BlockedUserFilter.visibleBoosts(
        post.boosts ?? const <Boost>[],
        blockedUsernames,
      ).isNotEmpty;
      if (hasBoosts) {
        danmakuActive = !ref.watch(
          topicSessionProvider(topicId)
              .select((s) => s.danmakuOffPostIds.contains(post.id)),
        );
      }
    }
    return PostSegmentFrame(
      post: post,
      selected: selected,
      highlight: highlight,
      showBottomDateSeparator: bottomDateSeparatorLabel != null,
      bottomDateSeparatorLabel: bottomDateSeparatorLabel,
      child: Column(
        crossAxisAlignment: VscodePostSource.enabled(context)
            ? CrossAxisAlignment.stretch
            : CrossAxisAlignment.start,
        children: [
          if (!VscodePostSource.enabled(context) &&
              PostSignatureBlock.shouldRender(
                ref,
                post,
                categoryId: categoryId,
              ))
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: PostSignatureBlock(post: post, categoryId: categoryId),
            ),
          PostFooterSection(
            post: post,
            topicId: topicId,
            topicHasAcceptedAnswer: topicHasAcceptedAnswer,
            acceptedAnswers: acceptedAnswers,
            padding: VscodePostSource.enabled(context)
                ? EdgeInsets.zero
                : const EdgeInsets.fromLTRB(16, 12, 16, 16),
            highlightBoostUsername: highlightBoostUsername,
            danmakuActive: danmakuActive,
            onReply: onReply,
            onEdit: onEdit,
            onShareAsImage: onShareAsImage,
            onRefreshPost: onRefreshPost,
            onJumpToPost: onJumpToPost,
            onSolutionChanged: onSolutionChanged,
            useReplyDialog: useReplyDialog,
            topicTitle: topicTitle,
            isPrivateMessageTopic: isPrivateMessageTopic,
            isPmWithNonHumanUser: isPmWithNonHumanUser,
            onShowPostDetail: onShowPostDetail,
            opTopSlot: opTopSlot,
            isPostVotingTopic: isPostVotingTopic,
            topicClosed: topicClosed,
          ),
        ],
      ),
    );
  }
}
