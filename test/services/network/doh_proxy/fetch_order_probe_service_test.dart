import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/network/doh_proxy/fetch_order_probe_service.dart';

void main() {
  group('FetchOrderProbeService', () {
    late List<Uri> probed;
    late int pending;
    late bool eligible;

    FetchOrderProbeService create({Future<void> Function(Uri url)? probe}) {
      return FetchOrderProbeService.forTesting(
        eligible: () => eligible,
        pending: () => pending,
        probe:
            probe ??
            (url) async {
              probed.add(url);
              pending = 0;
            },
      );
    }

    setUp(() {
      probed = [];
      pending = 2;
      eligible = true;
    });

    test('有待采组合时打开本站的采样页', () async {
      await create().maybeRun(reason: 'test');
      expect(probed, hasLength(1));
      expect(probed.single.path, FetchOrderProbeService.probePath);
      expect(probed.single.scheme, 'https');
    });

    test('条件不满足或没有待采组合时不采', () async {
      eligible = false;
      final service = create();
      await service.maybeRun(reason: 'test');
      eligible = true;
      pending = 0;
      await service.maybeRun(reason: 'test');
      expect(probed, isEmpty);
    });

    test('两次之间至少隔一段时间', () async {
      final service = create();
      await service.maybeRun(reason: 'first');
      pending = 3;
      await service.maybeRun(reason: 'second');
      expect(probed, hasLength(1));
    });

    test('并发调用只采一次', () async {
      final gate = Completer<void>();
      final service = create(
        probe: (url) async {
          probed.add(url);
          await gate.future;
        },
      );
      final first = service.maybeRun(reason: 'a');
      final second = service.maybeRun(reason: 'b');
      gate.complete();
      await Future.wait([first, second]);
      expect(probed, hasLength(1));
    });

    test('采样出错不往外抛', () async {
      final service = create(
        probe: (url) async => throw StateError('load failed'),
      );
      await expectLater(service.maybeRun(reason: 'test'), completes);
    });
  });
}
