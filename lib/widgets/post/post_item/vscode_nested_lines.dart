import '../../../models/nested_reading_position.dart';
import '../../../models/nested_topic.dart';
import '../../../utils/blocked_user_filter.dart';
import 'post_render_prep.dart';
import 'vscode_line_index.dart';

typedef VscodeNestedDisplayState = ({bool expanded, bool collapsed});

/// 源码索引与卡片共用最新正文，普通树形视图仍沿用上游合并语义。
NestedNode mergeVscodeNestedNode(NestedNode original, NestedNode incoming) {
  final children = [...original.children];
  for (final child in incoming.children) {
    final index = children.indexWhere((node) => node.post.id == child.post.id);
    if (index < 0) {
      children.add(child);
    } else {
      children[index] = mergeVscodeNestedNode(children[index], child);
    }
  }
  return original.copyWith(post: incoming.post, children: children);
}

/// 与树卡的折叠、深度和本地分页规则一致；只遍历已有数据，不展开或请求。
Iterable<VscodeLineEntry> vscodeNestedLines({
  required List<NestedNode> roots,
  required NestedReadingSession session,
  required Set<String> blockedUsernames,
  required int maxDepth,
  int? highlightPostNumber,
  Map<int, VscodeNestedDisplayState> displayStates = const {},
}) sync* {
  bool containsHighlight(NestedNode node) =>
      highlightPostNumber != null &&
      (node.post.postNumber == highlightPostNumber ||
          node.children.any(containsHighlight));

  Iterable<NestedNode> visibleNodes(Iterable<NestedNode> nodes) sync* {
    for (final node in nodes) {
      if (BlockedUserFilter.isBlockedUsername(node.post.username, blockedUsernames)) {
        yield* visibleNodes(node.children);
      } else {
        yield node;
      }
    }
  }

  Iterable<VscodeLineEntry> visit(NestedNode node, int depth) sync* {
    final branch = session.branches[node.post.postNumber];
    final children = visibleNodes(
      branch == null
          ? node.children
          : mergeVscodeNestedNode(node.copyWith(children: branch.children), node)
                .children,
    ).toList(growable: false);
    final hasReplies = node.directReplyCount > 0 || children.isNotEmpty;
    final expandedState = session.expanded[node.post.postNumber];
    final display = displayStates[node.post.id];
    final expanded = expandedState ?? display?.expanded ?? children.isNotEmpty;
    final collapsed = expandedState != null
        ? !expandedState && hasReplies
        : display?.collapsed ?? false;
    if (!collapsed &&
        !node.isDeletedPlaceholder &&
        !PostRenderPrep.isSystemPost(node.post)) {
      yield VscodeLineEntry(post: node.post, htmlUnits: [node.post.cooked]);
    }
    final containsTarget = containsHighlight(node);
    final atMaxDepth = !containsTarget && depth >= maxDepth;
    if (collapsed || !expanded || atMaxDepth) return;
    final showAll = highlightPostNumber != null || expandedState == true;
    final visible = showAll
        ? children
        : children.take(branch?.visibleCount ?? 3);
    for (final child in visible) {
      yield* visit(child, depth >= maxDepth && containsTarget ? 0 : depth + 1);
    }
  }

  for (final root in roots) {
    yield* visit(root, 0);
  }
}
