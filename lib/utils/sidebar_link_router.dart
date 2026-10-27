import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/sidebar_section.dart';
import '../pages/category_topics_page.dart';
import '../pages/tag_topics_page.dart';
import '../pages/topic_detail_page/topic_detail_page.dart';
import '../providers/category_provider.dart';
import 'discourse_url_parser.dart';
import 'link_launcher.dart';
import 'url_helper.dart';

/// 打开侧栏自定义分区里的一条链接：分类、标签进原生列表页，其余（话题、
/// 用户、站内其他页面、外链）交给 [launchContentLink] 按正文链接的规则走。
Future<void> openSidebarLink(
  BuildContext context,
  SidebarSectionLink link,
) async {
  final url = UrlHelper.resolveUrl(link.value.trim());
  if (url.isEmpty) return;
  if (isInternalUrlString(url)) {
    final categoryInfo = DiscourseUrlParser.parseCategory(url);
    if (categoryInfo != null) {
      final category = ProviderScope.containerOf(
        context,
        listen: false,
      ).read(categoryMapProvider).value?[categoryInfo.categoryId];
      if (category != null) {
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => CategoryTopicsPage(category: category),
          ),
        );
        return;
      }
    }
    final tag = DiscourseUrlParser.parseTag(url);
    if (tag != null && tag.isNotEmpty) {
      await Navigator.of(context)
          .push(MaterialPageRoute(builder: (_) => TagTopicsPage(tagName: tag)));
      return;
    }
  }
  if (!context.mounted) return;
  await launchContentLink(
    context,
    url,
    onInternalLinkTap: (topicId, _, postNumber) => Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            TopicDetailPage(topicId: topicId, scrollToPostNumber: postNumber),
      ),
    ),
  );
}
