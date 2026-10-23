import 'package:fluxdo/services/log/logger_utils.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('网络引擎计数摘要：握手合计、赛跑白做、等 pin 最长', () {
    final summary = LoggerUtils.netStatsSummary({
      'connect_ok': 12,
      'connect_fail': 1,
      'tls_full': 8,
      'tls_hrr': 1,
      'tls_resumed': 6,
      'race_handshake_ok': 5,
      'race_won': 2,
      'gw_h2_new': 9,
      'gw_h2_reuse': 120,
      'gw_h1_new': 0,
      'gw_502': 1,
      'loopback_accepts': 30,
      'pin_wait': {'n': 3, 'total_ms': 600, 'avg_ms': 200, 'max_ms': 512},
    });
    expect(
      summary,
      '建连 12/1败 握手 15(恢复 6) 赛跑白做 3 h2 新9/复用120 h1 0 502 1 '
      '等pin≤512ms 回环 30',
    );
  });

  test('旧库缺字段时按 0 处理', () {
    expect(
      LoggerUtils.netStatsSummary(const {}),
      '建连 0/0败 握手 0(恢复 0) 赛跑白做 0 h2 新0/复用0 h1 0 502 0 等pin≤0ms 回环 0',
    );
  });
}
