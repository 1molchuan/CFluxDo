import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fluxdo_render/fluxdo_render.dart';
import 'package:jovial_svg/jovial_svg.dart';
import '../../constants.dart';
import '../../l10n/s.dart';
import '../../models/topic.dart';
import '../../providers/discourse_providers.dart';
import '../../theme/mojian_theme.dart';
import '../../utils/fluxdo_render_callbacks.dart';
import '../../utils/time_utils.dart';
import '../common/smart_avatar.dart';
import '../common/flair_badge.dart';
import '../common/emoji_text.dart';
import 'share_image_preview.dart';

/// 分享图片 Widget
/// 用于生成可截图的分享图片
class ShareImageWidget extends ConsumerWidget {
  /// 话题详情
  final TopicDetail detail;

  /// 帖子（如果为 null，则显示主帖）
  final Post? post;

  /// 用于截图的 key
  final GlobalKey repaintBoundaryKey;

  /// 分享图片主题
  final ShareImageTheme shareTheme;

  const ShareImageWidget({
    super.key,
    required this.detail,
    this.post,
    required this.repaintBoundaryKey,
    required this.shareTheme,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = shareTheme.isDark;
    final bgColor = shareTheme.bgColor;
    final cardColor = shareTheme.cardColor;

    // 根据主题计算文字颜色
    final textColor = isDark ? Colors.white : Colors.black;
    final secondaryTextColor = isDark
        ? Colors.white.withValues(alpha: 0.6)
        : Colors.black.withValues(alpha: 0.6);
    final borderColor = isDark
        ? Colors.white.withValues(alpha: 0.1)
        : Colors.black.withValues(alpha: 0.1);

    // 优先使用传入的 post，否则查找主帖，最后使用第一个可用帖子
    final targetPost =
        post ??
        detail.postStream.posts.where((p) => p.postNumber == 1).firstOrNull ??
        detail.postStream.posts.firstOrNull;

    if (targetPost != null && shareTheme == ShareImageTheme.mojian) {
      return _buildMojian(context, ref, targetPost);
    }

    if (targetPost == null) {
      return RepaintBoundary(
        key: repaintBoundaryKey,
        child: Container(
          width: 375,
          padding: const EdgeInsets.all(40),
          color: bgColor,
          child: Center(
            child: Text(
              S.current.common_noContent,
              style: TextStyle(color: textColor),
            ),
          ),
        ),
      );
    }

    return RepaintBoundary(
      key: repaintBoundaryKey,
      child: Stack(
        children: [
          Container(
            width: 375,
            padding: const EdgeInsets.all(20),
            color: bgColor,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Logo
                _buildLogo(textColor),
                const SizedBox(height: 16),

                // 标题
                _buildTitle(context, textColor),
                const SizedBox(height: 12),

                // 作者信息
                _buildAuthorInfo(
                  context,
                  targetPost,
                  textColor,
                  secondaryTextColor,
                  borderColor,
                ),
                const SizedBox(height: 12),

                // 分隔线
                Container(height: 1, color: borderColor),
                const SizedBox(height: 12),

                // 内容
                _buildContent(targetPost, cardColor),

                const SizedBox(height: 16),

                // 分隔线
                Container(height: 1, color: borderColor),
                const SizedBox(height: 12),

                // 底部分享链接
                _buildShareLink(targetPost, secondaryTextColor),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 墨笺版式：报头双线 + 宋体小报名、分类与标签一行、宋体大标题、
  /// 署名一行，正文直接排在纸上（与详情页同一套正文字样），细线收尾附链接
  Widget _buildMojian(BuildContext context, WidgetRef ref, Post post) {
    final theme = Theme.of(context);
    final mj =
        theme.extension<MojianTokens>() ??
        MojianTokens.of(Brightness.light, MojianAccent.cinnabar);
    final category = ref.watch(categoryMapProvider).value?[detail.categoryId];
    final tags = detail.tags ?? const <Tag>[];
    final small = TextStyle(fontSize: 12, color: mj.ink3, height: 1.4);
    final titleStyle = TextStyle(
      fontFamily: MojianTokens.serifFamily,
      fontSize: 21,
      fontWeight: FontWeight.w700,
      height: 1.42,
      letterSpacing: 0.3,
      color: mj.ink,
    );
    final name = post.name?.isNotEmpty == true ? post.name! : post.username;

    return RepaintBoundary(
      key: repaintBoundaryKey,
      child: Container(
        width: 375,
        color: mj.paper,
        padding: const EdgeInsets.fromLTRB(22, 20, 22, 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 报头：粗墨线 + 细线，下面是报名
            Container(height: 1.5, color: mj.ink),
            const SizedBox(height: 3),
            Container(height: 0.6, color: mj.ruleStrong),
            const SizedBox(height: 10),
            Row(
              children: [
                SizedBox(
                  width: 18,
                  height: 18,
                  child: ScalableImageWidget.fromSISource(
                    si: ScalableImageSource.fromSvg(
                      rootBundle,
                      'assets/logo.svg',
                      warnF: (_) {},
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  'LINUX DO',
                  style: TextStyle(
                    fontFamily: MojianTokens.serifFamily,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 2.4,
                    color: mj.ink2,
                  ),
                ),
                const Spacer(),
                Text(TimeUtils.formatShortDate(post.createdAt), style: small),
              ],
            ),
            const SizedBox(height: 18),
            if (category != null || tags.isNotEmpty) ...[
              Text.rich(
                TextSpan(
                  children: [
                    if (category != null) ...[
                      WidgetSpan(
                        alignment: PlaceholderAlignment.middle,
                        child: Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: MojianTheme.categoryColor(
                                category.color,
                                Brightness.light,
                              ),
                              borderRadius: BorderRadius.circular(1.5),
                            ),
                            child: const SizedBox(width: 7, height: 7),
                          ),
                        ),
                      ),
                      TextSpan(
                        text: category.name,
                        style: TextStyle(
                          color: mj.ink2,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                    for (final tag in tags) ...[
                      const TextSpan(text: '   '),
                      TextSpan(
                        text: '#',
                        style: TextStyle(color: mj.ink4),
                      ),
                      TextSpan(text: tag.name),
                    ],
                  ],
                ),
                style: small,
              ),
              const SizedBox(height: 8),
            ],
            Text.rich(
              TextSpan(
                style: titleStyle,
                children: EmojiText.buildEmojiSpans(
                  context,
                  detail.title,
                  titleStyle,
                ),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                SmartAvatar(
                  imageUrl: post.getAvatarUrl(size: 72),
                  radius: 10,
                  fallbackText: post.username,
                  backgroundColor: mj.paper2,
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: name,
                          style: TextStyle(color: mj.ink2),
                        ),
                        TextSpan(
                          text:
                              ' · ${TimeUtils.formatRelativeTime(post.createdAt)}',
                        ),
                      ],
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: small.copyWith(fontSize: 12.5),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Container(height: 0.6, color: mj.rule),
            const SizedBox(height: 14),
            _buildContent(
              post,
              Colors.transparent,
              padding: EdgeInsets.zero,
              baseTextStyle: MojianTheme.postBodyStyle(theme, 1.0),
            ),
            const SizedBox(height: 18),
            Container(height: 0.6, color: mj.rule),
            const SizedBox(height: 10),
            _buildShareLink(post, mj.ink3),
          ],
        ),
      ),
    );
  }

  Widget _buildLogo(Color textColor) {
    return Row(
      children: [
        SizedBox(
          width: 28,
          height: 28,
          child: ScalableImageWidget.fromSISource(
            si: ScalableImageSource.fromSvg(
              rootBundle,
              'assets/logo.svg',
              warnF: (_) {},
            ),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          'LINUX DO',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: textColor.withValues(alpha: 0.8),
          ),
        ),
      ],
    );
  }

  Widget _buildTitle(BuildContext context, Color textColor) {
    final titleStyle = TextStyle(
      fontSize: 16,
      fontWeight: FontWeight.w600,
      color: textColor.withValues(alpha: 0.9),
      height: 1.4,
    );

    return Text.rich(
      TextSpan(
        style: titleStyle, // 设置父 TextSpan 的默认样式
        children: EmojiText.buildEmojiSpans(context, detail.title, titleStyle),
      ),
    );
  }

  Widget _buildAuthorInfo(
    BuildContext context,
    Post post,
    Color textColor,
    Color secondaryTextColor,
    Color borderColor,
  ) {
    final fullAvatarUrl = post.getAvatarUrl(size: 120);

    return Row(
      children: [
        AvatarWithFlair(
          flairSize: 14,
          flairRight: -3,
          flairBottom: -1,
          flairUrl: post.flairUrl,
          flairName: post.flairName,
          flairBgColor: post.flairBgColor,
          flairColor: post.flairColor,
          avatar: SmartAvatar(
            imageUrl: fullAvatarUrl,
            radius: 18,
            fallbackText: post.username,
            backgroundColor: Colors.grey.shade300,
            border: Border.all(color: borderColor, width: 1),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                post.name?.isNotEmpty == true ? post.name! : post.username,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: textColor.withValues(alpha: 0.85),
                ),
              ),
              Text(
                '@${post.username} · ${TimeUtils.formatRelativeTime(post.createdAt)}',
                style: TextStyle(fontSize: 12, color: secondaryTextColor),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildContent(
    Post post,
    Color cardColor, {
    EdgeInsets padding = const EdgeInsets.all(12),
    TextStyle? baseTextStyle,
  }) {
    // 预处理 cooked(注入 mention 状态 emoji + 链接点击数),与详情页一致,
    // 保证截图里 mention/click-count 等动态内容也能渲染。
    final preprocessed = FluxdoRenderCallbacks.preprocessCookedForRender(post);
    final parsedNodes = List<BlockNode>.unmodifiable(
      ParagraphParser().parse(preprocessed),
    );
    // 复用主项目接入层(图片/emoji/mention/代码高亮/quote 头像/onebox 等),
    // 与详情页 post_item.dart 注入同一套 callback。
    final callbacks = FluxdoRenderCallbacks.forPost(
      post: post,
      preprocessedCooked: preprocessed,
      parsedNodes: parsedNodes,
    );

    return Container(
      width: double.infinity,
      padding: padding,
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(8),
      ),
      // 整帖非分块渲染:FluxdoRender 内部就是一个 Column(无虚拟化),适合离屏
      // RepaintBoundary 全量截图;超高图由 screenshot_utils 分块拼接处理。
      // 截图场景关闭选区(selectionEnabled:false),不接 quote 交互回调。
      // 文字颜色走 Theme —— ShareImagePreview 已用对应 brightness 的 Theme
      // 包裹本 widget,故新引擎从 textTheme 取色能匹配卡片亮/暗背景。
      child: FluxdoRender(
        cookedHtml: preprocessed,
        parsedNodes: parsedNodes,
        baseTextStyle: baseTextStyle,
        selectionEnabled: false,
        screenshotMode: true,
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
      ),
    );
  }

  Widget _buildShareLink(Post post, Color secondaryTextColor) {
    final url =
        '${AppConstants.baseUrl}/t/${detail.slug}/${detail.id}/${post.postNumber}';

    return Row(
      children: [
        Icon(Symbols.link_rounded, size: 14, color: secondaryTextColor),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            url,
            style: TextStyle(fontSize: 11, color: secondaryTextColor),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}
