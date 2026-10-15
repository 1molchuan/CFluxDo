import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/models/topic.dart';
import 'package:fluxdo/providers/topic_detail/post_stream_window.dart';

/// 测试约定:帖子 id == 楼层号,便于读断言
Post _post(int id, {int? postNumber, int replyTo = 0, int replyCount = 0}) {
  return Post(
    id: id,
    username: 'user$id',
    avatarTemplate: '',
    cooked: '<p>$id</p>',
    postNumber: postNumber ?? id,
    postType: 1,
    updatedAt: DateTime(2026),
    createdAt: DateTime(2026),
    likeCount: 0,
    replyCount: replyCount,
    replyToPostNumber: replyTo,
  );
}

List<int> _range(int from, int to) => [for (var i = from; i <= to; i++) i];

List<Post> _posts(Iterable<int> ids) => [for (final id in ids) _post(id)];

List<int> _ids(PostStreamWindow window) =>
    window.posts.map((p) => p.id).toList();

PostStreamWindow _window(
  List<int> stream,
  Iterable<int> loaded, {
  PostStreamGaps? gaps,
}) {
  return PostStreamWindow.of(
    PostStream(posts: _posts(loaded), stream: stream, gaps: gaps),
  );
}

void main() {
  group('边界推导', () {
    test('首末已加载帖在 stream 中间时两侧都还有', () {
      final window = _window(_range(1, 10), _range(4, 6));

      expect(window.firstLoadedIndex, 3);
      expect(window.lastLoadedIndex, 5);
      expect(window.hasMoreBefore, isTrue);
      expect(window.hasMoreAfter, isTrue);
      expect(window.change, PostWindowChange.reset);
    });

    test('已加载覆盖整条 stream 时两侧都到头', () {
      final window = _window(_range(1, 5), _range(1, 5));

      expect(window.hasMoreBefore, isFalse);
      expect(window.hasMoreAfter, isFalse);
    });

    test('无已加载帖或末帖不在 stream 中时视为到头', () {
      expect(_window(_range(1, 5), const []).hasMoreAfter, isFalse);
      expect(_window(_range(1, 5), const []).hasMoreBefore, isFalse);

      final orphan = _window([1, 2, 3], [2, 99]);
      expect(orphan.hasMoreAfter, isFalse);
    });

    test('翻页请求的 id 段按边界截取', () {
      final window = _window(_range(1, 30), _range(11, 12));

      expect(window.idsAfter(5), [13, 14, 15, 16, 17]);
      expect(window.idsAfter(100), _range(13, 30));
      expect(window.idsBefore(3), [8, 9, 10]);
      expect(window.idsBefore(100), _range(1, 10));
      expect(_window(_range(1, 3), _range(1, 3)).idsAfter(5), isEmpty);
    });

    test('stream 位置表随 stream 实例缓存', () {
      final window = _window(_range(1, 10), _range(4, 6));
      final updated = window.updatePost(5, (p) => p.copyWith(likeCount: 3));

      expect(identical(updated.stream, window.stream), isTrue);
      expect(
        identical(updated.streamPositions, window.streamPositions),
        isTrue,
      );
    });
  });

  group('向下翻页', () {
    test('新页接到末尾,只排序新页', () {
      final window = _window(_range(1, 10), _range(4, 6));

      final next = window.appendPage([_post(8), _post(7)]);

      expect(_ids(next), [4, 5, 6, 7, 8]);
      expect(next.hasMoreAfter, isTrue);
      expect(next.change, PostWindowChange.append);
      expect(identical(next.stream, window.stream), isTrue);
    });

    test('翻页期间实时 id 11 已入 stream:应用到最新窗口后 11 仍在', () {
      final requested = _window(_range(1, 10), _range(4, 6));
      // 请求在途时 MessageBus 推来 11(未到底分支只记 id)
      final latest = requested.withLivePostId(11);

      final next = latest.appendPage(_posts(_range(7, 10)));

      expect(next.stream, _range(1, 11));
      expect(_ids(next), _range(4, 10));
      expect(next.hasMoreAfter, isTrue, reason: '11 还没加载内容');
      expect(next.idsAfter(20), [11]);
    });

    test('页里有 stream 没有的新帖时 id 补到 stream 末尾', () {
      final window = _window(_range(1, 6), _range(4, 6));

      final next = window.appendPage([_post(7)]);

      expect(next.stream, _range(1, 7));
      expect(next.hasMoreAfter, isFalse);
    });

    test('空页(或只有已加载的帖)= 到头,不再空翻', () {
      // stream 尾部 9、10 取不到内容(如已删帖)
      final window = _window(_range(1, 10), _range(4, 8));

      final empty = window.appendPage(const []);
      expect(empty.hasMoreAfter, isFalse);
      expect(empty.exhaustedAfter, isTrue);
      expect(empty.change, PostWindowChange.stream);
      expect(_ids(empty), _range(4, 8));

      final dupes = window.appendPage([_post(8)]);
      expect(dupes.hasMoreAfter, isFalse);

      // 已到头再来一次空页:窗口不变
      expect(identical(empty.appendPage(const []), empty), isTrue);
      // 到头不影响另一侧
      expect(empty.hasMoreBefore, isTrue);
    });

    test('过滤视图按 stream 下标排新页', () {
      // 过滤视图的 stream 不是楼层顺序
      final window = PostStreamWindow.of(
        PostStream(posts: [_post(1)], stream: const [1, 30, 12, 25]),
      );

      final next = window.appendPage([
        _post(25),
        _post(12),
        _post(30),
      ], orderByStream: true);

      expect(_ids(next), [1, 30, 12, 25]);
      expect(next.hasMoreAfter, isFalse);
    });
  });

  group('向上翻页', () {
    test('新页接到开头', () {
      final window = _window(_range(1, 10), _range(4, 6));

      final prev = window.prependPage([_post(3), _post(2)]);

      expect(_ids(prev), _range(2, 6));
      expect(prev.hasMoreBefore, isTrue);
      expect(prev.change, PostWindowChange.prepend);

      final top = prev.prependPage([_post(1)]);
      expect(top.hasMoreBefore, isFalse);
      expect(top.hasMoreAfter, isTrue);
    });

    test('页里有 stream 没有的帖时 id 补到 stream 开头', () {
      final window = _window(_range(4, 10), _range(4, 6));

      final prev = window.prependPage([_post(3)]);

      expect(prev.stream.first, 3);
      expect(prev.hasMoreBefore, isFalse);
    });

    test('空页 = 顶部到头', () {
      final window = _window(_range(1, 10), _range(4, 6));

      final prev = window.prependPage(const []);

      expect(prev.hasMoreBefore, isFalse);
      expect(prev.exhaustedBefore, isTrue);
      expect(prev.hasMoreAfter, isTrue);
    });
  });

  group('gap 拼接', () {
    test('stream 1..10、已加载 4..6、6 之后的 gap = [7,8]:拼接后已加载 4..8', () {
      final window = _window(
        _range(1, 10),
        _range(4, 6),
        gaps: const PostStreamGaps(
          after: {
            6: [7, 8],
          },
        ),
      );

      final next = window.spliceGap(
        6,
        before: false,
        gapPostIds: const [7, 8],
        fetched: _posts([7, 8]),
      );

      expect(_ids(next), _range(4, 8));
      expect(next.stream, _range(1, 10), reason: 'id 已在 stream 里,不重复插入');
      expect(next.hasMoreAfter, isTrue);
      expect(next.hasMoreBefore, isTrue);
    });

    test('gap id 不在 stream 里时整段拼到锚点原位', () {
      // 过滤视图:7、8 被跳过,不在 stream 里
      final window = _window(
        [1, 2, 3, 4, 5, 6, 9, 10],
        _range(4, 6),
        gaps: const PostStreamGaps(
          after: {
            6: [7, 8],
          },
        ),
      );

      final next = window.spliceGap(
        6,
        before: false,
        gapPostIds: const [7, 8],
        fetched: [_post(8), _post(7)],
      );

      expect(_ids(next), _range(4, 8));
      expect(next.stream, _range(1, 10));
      expect(next.hasMoreAfter, isTrue);
      expect(next.gaps, isNull, reason: '唯一的 gap 补齐后与服务端「无 gap」一致');
      expect(next.change, PostWindowChange.gap);
    });

    test('gap 在末帖之后:拼完到底,不再永远 hasMoreAfter', () {
      final window = _window(
        _range(1, 6),
        _range(4, 6),
        gaps: const PostStreamGaps(
          after: {
            6: [7, 8],
          },
          before: {
            4: [3],
          },
        ),
      );

      final next = window.spliceGap(
        6,
        before: false,
        gapPostIds: const [7, 8],
        fetched: _posts([7, 8]),
      );

      expect(next.stream.last, 8);
      expect(next.hasMoreAfter, isFalse);
      expect(next.gaps!.after, isEmpty);
      expect(next.gaps!.before, {
        4: [3],
      });
    });

    test('gap 在锚点帖之前,只收实际拉到的 id', () {
      final window = _window(
        [1, 2, 5, 6],
        [5, 6],
        gaps: const PostStreamGaps(
          before: {
            5: [3, 4],
          },
        ),
      );

      final next = window.spliceGap(
        5,
        before: true,
        gapPostIds: const [3, 4],
        fetched: [_post(4)],
      );

      expect(_ids(next), [4, 5, 6]);
      expect(next.stream, [1, 2, 4, 5, 6]);
    });
  });

  group('实时新回复', () {
    test('未到底:只记 id,内容等翻页', () {
      final window = _window(_range(1, 10), _range(4, 6));

      final next = window.withLivePostId(11);

      expect(next.stream.last, 11);
      expect(_ids(next), _range(4, 6));
      expect(next.change, PostWindowChange.stream);
      expect(identical(next.withLivePostId(11), next), isTrue);
    });

    test('到底:内容与 id 同帧落地,被回复楼层 replyCount + 1', () {
      final window = _window(_range(1, 5), _range(1, 5));
      expect(window.hasMoreAfter, isFalse);

      final next = window.landLivePosts([_post(7, replyTo: 2), _post(6)]);

      expect(_ids(next), _range(1, 7));
      expect(next.stream, _range(1, 7));
      expect(next.hasMoreAfter, isFalse);
      expect(next.posts[1].replyCount, 1);
      expect(next.change, PostWindowChange.append);
    });

    test('落地时窗口已不在底部:只记 id,不在中间留空洞', () {
      final window = _window(_range(1, 10), _range(4, 6));

      final next = window.landLivePosts([_post(11)]);

      expect(_ids(next), _range(4, 6));
      expect(next.stream.last, 11);
    });

    test('已加载的新帖不重复落地', () {
      final window = _window(_range(1, 5), _range(1, 5));
      expect(identical(window.landLivePosts([_post(5)]), window), isTrue);
    });
  });

  group('自己的回复', () {
    test('到底时按楼层号插入并记 id', () {
      final window = _window(_range(1, 5), _range(1, 5));

      final result = window.addOwnPost(_post(6));

      expect(result.loaded, isTrue);
      expect(_ids(result.window), _range(1, 6));
      expect(result.window.hasMoreAfter, isFalse);
    });

    test('未到底时只记 id;wasAtBottom 快照仍直接插入', () {
      final window = _window(_range(1, 10), _range(4, 6));

      final notLoaded = window.addOwnPost(_post(11));
      expect(notLoaded.loaded, isFalse);
      expect(_ids(notLoaded.window), _range(4, 6));
      expect(notLoaded.window.stream.last, 11);

      final snapshot = window.addOwnPost(_post(11), wasAtBottom: true);
      expect(snapshot.loaded, isTrue);
      expect(_ids(snapshot.window).last, 11);
    });

    test('已在已加载楼层里时窗口不变', () {
      final window = _window(_range(1, 5), _range(1, 5));
      final result = window.addOwnPost(_post(5));
      expect(result.loaded, isTrue);
      expect(identical(result.window, window), isTrue);
    });
  });

  group('移除与替换', () {
    test('移除已加载帖:posts 与 stream 一并删', () {
      final window = _window(_range(1, 10), _range(4, 6));

      final next = window.removePost(6);

      expect(_ids(next), [4, 5]);
      expect(next.stream, [1, 2, 3, 4, 5, 7, 8, 9, 10]);
      expect(next.hasMoreAfter, isTrue);
      expect(next.change, PostWindowChange.remove);
    });

    test('只在 stream 里的帖也移除;删掉尾部唯一未加载帖后到底', () {
      final window = _window(_range(1, 6), _range(1, 5));
      expect(window.hasMoreAfter, isTrue);

      final next = window.removePost(6);

      expect(next.stream, _range(1, 5));
      expect(next.hasMoreAfter, isFalse);
    });

    test('窗口里没有的帖移除时窗口不变', () {
      final window = _window(_range(1, 5), _range(1, 5));
      expect(identical(window.removePost(42), window), isTrue);
    });

    test('替换单帖不动 stream 与边界', () {
      final window = _window(_range(1, 10), _range(4, 6));

      final next = window.replacePost(_post(5).copyWith(likeCount: 9));

      expect(next.posts[1].likeCount, 9);
      expect(identical(next.stream, window.stream), isTrue);
      expect(next.hasMoreAfter, window.hasMoreAfter);
      expect(next.change, PostWindowChange.update);
      expect(identical(window.replacePost(_post(42)), window), isTrue);
    });

    test('updatePost 原样返回时窗口不变;mapPosts 只在有帖变化时换实例', () {
      final window = _window(_range(1, 5), _range(1, 5));

      expect(identical(window.updatePost(3, (p) => p), window), isTrue);
      expect(identical(window.mapPosts((p) => p), window), isTrue);

      final mapped = window.mapPosts(
        (p) => p.id == 2 ? p.copyWith(acceptedAnswer: true) : p,
      );
      expect(mapped.posts[1].acceptedAnswer, isTrue);
      expect(identical(mapped.posts[0], window.posts[0]), isTrue);
    });

    test('窗口变化保留到头标记', () {
      final window = _window(_range(1, 10), _range(4, 8)).appendPage(const []);

      final next = window.replacePost(_post(5).copyWith(likeCount: 1));

      expect(next.exhaustedAfter, isTrue);
      expect(next.hasMoreAfter, isFalse);
    });
  });

  group('整页响应建窗口', () {
    test('补常驻 1 楼:posts 与 stream 开头都补上', () {
      final window = PostStreamWindow.fromPostStream(
        PostStream(posts: _posts([3, 5]), stream: const [3, 5, 8]),
        pinnedFirstPost: _post(1),
      );

      expect(_ids(window), [1, 3, 5]);
      expect(window.stream, [1, 3, 5, 8]);
      expect(window.hasMoreBefore, isFalse);
      expect(window.hasMoreAfter, isTrue);
    });

    test('响应已含 1 楼时不重复补', () {
      final window = PostStreamWindow.fromPostStream(
        PostStream(posts: _posts([1, 2]), stream: const [1, 2]),
        pinnedFirstPost: _post(1),
      );

      expect(_ids(window), [1, 2]);
    });

    test('of() 对已是窗口的 PostStream 原样返回', () {
      final window = _window(_range(1, 3), _range(1, 3));
      expect(identical(PostStreamWindow.of(window), window), isTrue);
    });
  });
}
