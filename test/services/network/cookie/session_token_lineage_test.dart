import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/network/cookie/session_token_lineage.dart';

void main() {
  final lineage = SessionTokenLineage.instance;

  setUp(() => lineage.resetForTest());

  group('SessionTokenLineage.tokenHash', () {
    test('空值返回 null，非空返回 12 位十六进制且不含原文', () {
      expect(SessionTokenLineage.tokenHash(null), isNull);
      expect(SessionTokenLineage.tokenHash(''), isNull);
      final hash = SessionTokenLineage.tokenHash('abcdef0123456789abcdef0123456789');
      expect(hash, hasLength(12));
      expect(RegExp(r'^[0-9a-f]{12}$').hasMatch(hash!), isTrue);
      expect(hash, isNot(contains('abcdef0123456789')));
    });

    test('不同 token 得到不同哈希，相同 token 稳定', () {
      final a = SessionTokenLineage.tokenHash('token-a');
      final b = SessionTokenLineage.tokenHash('token-b');
      expect(a, isNot(equals(b)));
      expect(SessionTokenLineage.tokenHash('token-a'), equals(a));
    });
  });

  group('SessionTokenLineage 候选环与一致记录', () {
    test('记录的候选按新到旧排序、去重、最多保留 4 枚', () {
      for (final v in ['t1', 't2', 't3', 't2', 't4', 't5']) {
        lineage.noteWebViewCandidate(v);
      }
      expect(lineage.recentWebViewCandidates(), ['t5', 't4', 't2', 't3']);
    });

    test('exclude 过滤掉 jar / 已发送 / 当前值，空值忽略', () {
      lineage.noteWebViewCandidate('old');
      lineage.noteWebViewCandidate('new');
      lineage.noteWebViewCandidate(null);
      lineage.noteWebViewCandidate('');
      expect(
        lineage.recentWebViewCandidates(exclude: ['new', null]),
        ['old'],
      );
    });

    test('标记一致的值不再出现在候选环里，也不会再被记入', () {
      lineage.noteWebViewCandidate('a');
      lineage.noteWebViewCandidate('b');
      lineage.markAgreed('a');
      expect(lineage.recentWebViewCandidates(), ['b']);
      expect(lineage.lastAgreedHash, SessionTokenLineage.tokenHash('a'));

      lineage.noteWebViewCandidate('a');
      expect(lineage.recentWebViewCandidates(), ['b']);
    });

    test('clear 清空一致记录与候选环', () {
      lineage.noteWebViewCandidate('x');
      lineage.markAgreed('y');
      lineage.clear();
      expect(lineage.recentWebViewCandidates(), isEmpty);
      expect(lineage.lastAgreedHash, isNull);
    });
  });
}
