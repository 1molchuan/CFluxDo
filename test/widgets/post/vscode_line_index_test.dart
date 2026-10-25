import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/models/nested_reading_position.dart';
import 'package:fluxdo/models/nested_topic.dart';
import 'package:fluxdo/models/topic.dart';
import 'package:fluxdo/widgets/post/post_item/post_render_prep.dart';
import 'package:fluxdo/widgets/post/post_item/vscode_line_index.dart';
import 'package:fluxdo/widgets/post/post_item/vscode_nested_lines.dart';
import 'package:fluxdo/widgets/post/post_item/widgets/vscode_post_source.dart';

Post _post(int id, String cooked) => Post(
  id: id,
  username: 'user$id',
  avatarTemplate: '',
  cooked: cooked,
  postNumber: id,
  postType: 1,
  updatedAt: DateTime(2026),
  createdAt: DateTime(2026),
  likeCount: 0,
  replyCount: 0,
);

int _lines(String html) => 1 + VscodeSourceDocument.forHtml(html).lineCount;

void main() {
  test('部分加载按展示顺序连续编号，插入、编辑和筛选重新计算后续起点', () {
    final index = VscodeLineIndex();
    final first = VscodeLineEntry(
      post: _post(40, '<p>甲</p>'),
      htmlUnits: ['<p>甲</p>'],
    );
    final last = VscodeLineEntry(
      post: _post(90, '<p>乙</p>'),
      htmlUnits: ['<p>乙</p>'],
    );
    index.update([first, last]);
    expect(index.firstLineOf(40), 1);
    expect(index.firstLineOf(90), 1 + _lines(first.htmlUnits.single));

    final inserted = VscodeLineEntry(
      post: _post(12, '<p>前页</p>'),
      htmlUnits: ['<p>前页</p>'],
    );
    final edited = VscodeLineEntry(
      post: _post(40, '<p>甲</p><p>编辑后新增正文</p>'),
      htmlUnits: ['<p>甲</p><p>编辑后新增正文</p>'],
    );
    index.update([inserted, edited, last]);
    expect(
      index.firstLineOf(90),
      1 + _lines(inserted.htmlUnits.single) + _lines(edited.htmlUnits.single),
    );
    index.update([last, edited]);
    expect(index.firstLineOf(90), 1);
    expect(index.firstLineOf(40), 1 + _lines(last.htmlUnits.single));
    expect(index.firstLineOf(12), 1);

    final anotherTopic = VscodeLineIndex()..update([edited]);
    expect(anotherTopic.firstLineOf(40), 1);
  });

  test('真实长帖分块与前后短帖共享连续起点，重复更新不丢块偏移', () {
    final html = List.generate(
      50,
      (i) => '<p>第 $i 段：${List.filled(80, '正文').join()}</p>',
    ).join();
    final plan = PostRenderPrep.planFor(_post(80001, html));
    expect(plan.isLong, isTrue);
    final units = [for (final chunk in plan.chunks) chunk.html];
    final entries = [
      VscodeLineEntry(post: _post(1, '<p>开头</p>'), htmlUnits: ['<p>开头</p>']),
      VscodeLineEntry(post: plan.post, htmlUnits: units),
      VscodeLineEntry(post: _post(99, '<p>末尾</p>'), htmlUnits: ['<p>末尾</p>']),
    ];
    final index = VscodeLineIndex();
    for (var update = 0; update < 2; update++) {
      index.update(entries);
      var next = 1 + _lines('<p>开头</p>');
      for (var unit = 0; unit < units.length; unit++) {
        expect(index.firstLineOf(80001, unitIndex: unit), next);
        next += VscodeSourceDocument.forHtml(units[unit]).lineCount;
        if (unit == 0) next++;
      }
      expect(index.firstLineOf(99), next);
    }
  });

  test('安全富文本仅作者元信息占行，系统信息不占行且不暴露折叠文字', () {
    const hidden = '<details><summary>折叠</summary>秘密正文</details>';
    final document = VscodeSourceDocument.forHtml(hidden);
    expect(document.preferRichText, isTrue);
    expect(document.lineCount, 0);
    final index = VscodeLineIndex()
      ..update([
        VscodeLineEntry(post: _post(1, hidden), htmlUnits: [hidden]),
        VscodeLineEntry(post: _post(2, ''), htmlUnits: []),
        VscodeLineEntry(
          post: _post(3, '<p>公开正文</p>'),
          htmlUnits: ['<p>公开正文</p>'],
        ),
      ]);
    expect(index.firstLineOf(1), 1);
    expect(index.firstLineOf(2), 2);
    expect(index.firstLineOf(3), 2);
  });

  test('树形只编号实际展开与本地分页范围，合并最新正文后更新后续楼层', () {
    final children = List.generate(
      5,
      (i) => NestedNode(post: _post(20 + i, '<p>子楼 $i</p>')),
    );
    final root = NestedNode(
      post: _post(10, '<p>父楼</p>'),
      children: children,
      directReplyCount: 8,
    );
    final tail = NestedNode(post: _post(90, '<p>后续根楼</p>'));
    final session = NestedReadingSession();
    final index = VscodeLineIndex();
    List<VscodeLineEntry> shown(List<NestedNode> roots) => vscodeNestedLines(
      roots: roots,
      session: session,
      blockedUsernames: const {},
      maxDepth: 10,
    ).toList();

    expect(shown([root, tail]).map((entry) => entry.postId), [
      10,
      20,
      21,
      22,
      90,
    ]);
    final limited = vscodeNestedLines(
      roots: [root, tail],
      session: session,
      blockedUsernames: const {'user21'},
      maxDepth: 0,
    ).map((entry) => entry.postId);
    expect(limited, [10, 90]);
    final filtered = vscodeNestedLines(
      roots: [root, tail],
      session: session,
      blockedUsernames: const {'user21'},
      maxDepth: 10,
    ).map((entry) => entry.postId);
    expect(filtered, [10, 20, 22, 23, 90]);
    session.expanded[10] = false;
    final folded = shown([root, tail]);
    expect(folded.map((entry) => entry.postId), [90]);
    index.update(folded);
    expect(index.firstLineOf(90), 1);

    session.expanded[10] = true;
    session.branches[10] = NestedBranchState(children: children, hasMore: true);
    final updated = root.copyWith(
      children: [
        children.first.copyWith(post: _post(20, '<p>修改</p><p>新增第二段</p>')),
      ],
    );
    final expanded = shown([updated, tail]);
    expect(expanded.map((entry) => entry.postId), [10, 20, 21, 22, 23, 24, 90]);
    expect(expanded[1].htmlUnits.single, '<p>修改</p><p>新增第二段</p>');
    index.update(expanded);
    expect(
      index.firstLineOf(90),
      1 +
          expanded
              .take(6)
              .fold<int>(
                0,
                (sum, entry) => sum + _lines(entry.htmlUnits.single),
              ),
    );
  });
}
