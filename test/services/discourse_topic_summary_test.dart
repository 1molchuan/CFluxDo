import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/discourse/discourse_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('已有话题摘要优先通过 GET 读取缓存，不触发生成请求', () async {
    // cfluxdo 的 Dio 拦截器链会读 SharedPreferences，测试里没有平台实现，
    // 先给个空的内存实现，否则请求在拦截器里就抛 MissingPluginException。
    SharedPreferences.setMockInitialValues({});
    final service = DiscourseService();
    final adapter = _CachedTopicSummaryAdapter();
    final originalAdapter = service.dio.httpClientAdapter;
    service.dio.httpClientAdapter = adapter;
    addTearDown(() => service.dio.httpClientAdapter = originalAdapter);

    final summary = await service.getTopicSummary(42);

    expect(adapter.requests, ['GET /discourse-ai/summarization/t/42']);
    expect(summary, isNotNull);
    expect(summary!.summarizedText, 'cached summary');
    expect(summary.outdated, isTrue);
    expect(summary.canRegenerate, isTrue);
    expect(summary.newPostsSinceSummary, 3);
  });

  test('过期摘要刷新明确走 skip_age_check 强制重生成链路', () {
    final providerSource = File(
      'lib/providers/topic_detail_provider.dart',
    ).readAsStringSync();
    final widgetSource = File(
      'lib/widgets/topic/topic_summary_widget.dart',
    ).readAsStringSync();

    expect(
      providerSource,
      contains('watchTopicSummary(topicId, skipAgeCheck: true)'),
    );
    expect(
      widgetSource,
      contains('topicSummaryRegenerationProvider(widget.topicId)'),
    );
    expect(widgetSource, contains('summaryAsyncOverride: summaryAsync'));
    expect(
      widgetSource,
      contains('.getTopicSummary(topicId, skipAgeCheck: true)'),
    );
  });
}

class _CachedTopicSummaryAdapter implements HttpClientAdapter {
  final List<String> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add('${options.method} ${options.uri.path}');
    expect(options.uri.path, '/discourse-ai/summarization/t/42');
    expect(options.method, 'GET');

    return ResponseBody.fromString(
      jsonEncode({
        'ai_topic_summary': {
          'summarized_text': 'cached summary',
          'algorithm': 'test',
          'outdated': true,
          'can_regenerate': true,
          'new_posts_since_summary': 3,
          'updated_at': '2026-10-02T05:00:00.000Z',
        },
      }),
      200,
      headers: {
        Headers.contentTypeHeader: const ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
