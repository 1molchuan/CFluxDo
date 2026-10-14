import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/network/doh_proxy/doh_proxy_ffi.dart';

void main() {
  group('DohAccelUpdate.isEmpty', () {
    test('什么都没有时为空', () {
      expect(const DohAccelUpdate().isEmpty, isTrue);
      expect(const DohAccelUpdate(reportAuthRejected: false).isEmpty, isTrue);
    });

    test('只有路由表 / 节点 / 信封任一项就不为空', () {
      expect(const DohAccelUpdate(routeTable: '{}').isEmpty, isFalse);
      expect(const DohAccelUpdate(nodes: '{}').isEmpty, isFalse);
      expect(const DohAccelUpdate(nodesEnvelopeJson: '{}').isEmpty, isFalse);
    });

    test('selectState 非空时不为空', () {
      expect(
        const DohAccelUpdate(selectState: '{"winner":null}').isEmpty,
        isFalse,
      );
    });

    test('reportAuthRejected 为 true 时不为空', () {
      expect(const DohAccelUpdate(reportAuthRejected: true).isEmpty, isFalse);
    });
  });

  group('DohSelectStatus.fromJson', () {
    test('winner 为 null：没有赢家，其他字段照常解析', () {
      final status = DohSelectStatus.fromJson({
        'ok': true,
        'mode': 'local_atlas',
        'phase': 'racing',
        'winner': null,
        'last_race_at': 0,
        'last_error': 'all candidates failed',
        'fail_streak': 2,
        'share': false,
        'keys': 0,
        'network_sig': 'wifi',
      });
      expect(status.mode, 'local_atlas');
      expect(status.phase, 'racing');
      expect(status.winnerIp, isNull);
      expect(status.latencyMs, isNull);
      expect(status.verifiedAt, isNull);
      expect(status.source, isNull);
      expect(status.echSource, isNull);
      expect(status.lastRaceAt, 0);
      expect(status.lastError, 'all candidates failed');
      expect(status.failStreak, 2);
      expect(status.share, isFalse);
      expect(status.hasWinner, isFalse);
    });

    test('有 winner 且 phase 为 ready：hasWinner 为 true', () {
      final status = DohSelectStatus.fromJson({
        'ok': true,
        'mode': 'local_atlas',
        'phase': 'ready',
        'winner': {
          'ip': '104.21.1.1',
          'latency_ms': 87,
          'verified_at': 1791988580,
          'source': 'vendor',
          'ech_source': 'atlas',
        },
        'last_race_at': 1791988580,
        'last_error': null,
        'fail_streak': 0,
        'share': true,
        'keys': 1,
        'network_sig': 'wifi',
      });
      expect(status.mode, 'local_atlas');
      expect(status.phase, 'ready');
      expect(status.winnerIp, '104.21.1.1');
      expect(status.latencyMs, 87);
      expect(status.verifiedAt, 1791988580);
      expect(status.source, 'vendor');
      expect(status.echSource, 'atlas');
      expect(status.lastRaceAt, 1791988580);
      expect(status.lastError, isNull);
      expect(status.failStreak, 0);
      expect(status.share, isTrue);
      expect(status.hasWinner, isTrue);
    });

    test('有 winner 但 phase 是 verifying：hasWinner 为 false', () {
      final status = DohSelectStatus.fromJson({
        'ok': true,
        'mode': 'local_atlas',
        'phase': 'verifying',
        'winner': {'ip': '104.21.1.1', 'latency_ms': 87},
        'last_race_at': 1,
        'fail_streak': 0,
        'share': false,
      });
      expect(status.winnerIp, '104.21.1.1');
      expect(status.hasWinner, isFalse);
    });

    test('toJson 再 fromJson 字段不丢（isolate 回传用）', () {
      final original = DohSelectStatus.fromJson({
        'mode': 'local_atlas',
        'phase': 'ready',
        'winner': {
          'ip': '2606:4700::1',
          'latency_ms': 120,
          'verified_at': 42,
          'source': 'random',
          'ech_source': 'vendor',
        },
        'last_race_at': 42,
        'last_error': null,
        'fail_streak': 0,
        'share': true,
      });
      final restored = DohSelectStatus.fromJson(original.toJson());
      expect(restored.mode, original.mode);
      expect(restored.phase, original.phase);
      expect(restored.winnerIp, original.winnerIp);
      expect(restored.latencyMs, original.latencyMs);
      expect(restored.verifiedAt, original.verifiedAt);
      expect(restored.source, original.source);
      expect(restored.echSource, original.echSource);
      expect(restored.lastRaceAt, original.lastRaceAt);
      expect(restored.lastError, original.lastError);
      expect(restored.failStreak, original.failStreak);
      expect(restored.share, original.share);
    });
  });
}
