import '../../../models/topic.dart';
import '../../../models/vscode_body_style.dart';
import 'widgets/vscode_post_source.dart';

/// 一个实际显示的正文单位；系统信息、折叠节点不占行号。
class VscodeLineEntry {
  const VscodeLineEntry({required this.post, required this.htmlUnits});

  final Post post;
  int get postId => post.id;
  final List<String> htmlUnits;
}

/// 页面私有的值索引，只统计 cooked 转换后的逻辑行，不创建排版对象。
///
/// 调用方在展示顺序变化时更新一次；item 构建只做常数时间查询。
/// 每楼缓存分块内容及行数，点赞等不改变正文的更新不会重复转换。
class VscodeLineIndex {
  final Map<int, _LineCounts> _counts = {};
  Map<int, int> _starts = const {};
  VscodeBodyStyle _style = VscodeBodyStyle.compact;
  VscodeCodeLanguage _language = VscodeCodeLanguage.java;

  int firstLineOf(int postId, {int unitIndex = 0}) {
    final start = _starts[postId];
    if (start == null) return 1;
    final offsets = _counts[postId]!.offsets;
    return start + (offsets.isEmpty ? 0 : offsets[unitIndex]);
  }

  void update(
    Iterable<VscodeLineEntry> entries, {
    VscodeBodyStyle style = VscodeBodyStyle.compact,
    VscodeCodeLanguage language = VscodeCodeLanguage.java,
  }) {
    if (_style != style || _language != language) {
      _counts.clear();
      _style = style;
      _language = language;
    }
    final starts = <int, int>{};
    var next = 1;
    for (final entry in entries) {
      var counts = _counts[entry.postId];
      if (counts == null || !counts.matches(entry)) {
        counts = _LineCounts(entry, style, language);
        _counts[entry.postId] = counts;
      }
      starts[entry.postId] = next;
      next += counts.total;
    }
    _counts.removeWhere((id, _) => !starts.containsKey(id));
    _starts = starts;
  }
}

class _LineCounts {
  _LineCounts(
    VscodeLineEntry entry,
    VscodeBodyStyle style,
    VscodeCodeLanguage language,
  ) : post = entry.post, units = List.of(entry.htmlUnits) {
    var count = 0;
    for (var i = 0; i < units.length; i++) {
      offsets.add(count);
      count += VscodeSourceDocument.forPost(
        post,
        html: units[i],
        style: style,
        language: language,
        firstUnit: i == 0,
        lastUnit: i == units.length - 1,
      ).lineCount;
    }
    total = count;
  }

  final Post post;
  final List<String> units;
  final List<int> offsets = [];
  late final int total;

  bool matches(VscodeLineEntry entry) {
    final otherPost = entry.post;
    if (post.postNumber != otherPost.postNumber ||
        post.username != otherPost.username) {
      return false;
    }
    final other = entry.htmlUnits;
    if (units.length != other.length) return false;
    for (var i = 0; i < units.length; i++) {
      if (units[i] != other[i]) return false;
    }
    return true;
  }
}
