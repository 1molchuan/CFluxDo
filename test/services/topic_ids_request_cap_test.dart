import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/discourse/discourse_service.dart';

/// 2026-11-20 日志：攒了一夜的新话题全带进 `/latest.json?topic_ids=…`，源站回 414，
/// 再长连本机网关都拒收（HttpException: Connection closed before full header）
void main() {
  test('按 ID 取话题：不超过上限时原样带上', () {
    expect(joinTopicIdsForRequest([3, 1, 2]), '3,1,2');
    expect(joinTopicIdsForRequest(const []), '');
  });

  test('按 ID 取话题：超过上限只留最新攒下的那些，地址不会被撑爆', () {
    final ids = [for (var i = 0; i < 2000; i++) 3200000 + i];
    final value = joinTopicIdsForRequest(ids);
    final sent = value.split(',');
    expect(sent, hasLength(maxTopicIdsPerRequest));
    expect(sent.first, '${ids[ids.length - maxTopicIdsPerRequest]}');
    expect(sent.last, '${ids.last}');
    // 逗号编码成 %2C 后也远小于常见的 8 KB 请求行上限
    expect(Uri.encodeQueryComponent(value).length, lessThan(2048));
  });
}
