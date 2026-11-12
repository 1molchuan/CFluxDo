import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/pages/network_settings_page/custom_nodes_page.dart';
import 'package:fluxdo/services/network/doh/custom_node_input.dart';
import 'package:fluxdo/services/network/doh_proxy/doh_proxy_ffi.dart';

/// 自定义节点页：入口摘要、每条节点的状态说明、添加对话框的校验
void main() {
  /// 引擎状态里 `custom.nodes` 的一项
  Map<String, dynamic> node(
    String entry,
    String state, {
    String? ip,
    int? latencyMs,
    String? detail,
    bool active = false,
  }) => {
    'entry': entry,
    'state': state,
    'ip': ip,
    'latency_ms': latencyMs,
    'detail': detail,
    'active': active,
  };

  DohSelectStatus status({
    String? winnerIp,
    String source = 'vendor',
    List<Map<String, dynamic>> nodes = const [],
    bool busy = false,
  }) => DohSelectStatus.fromJson({
    'mode': 'local_atlas',
    'phase': 'ready',
    'winner': winnerIp == null
        ? null
        : {'ip': winnerIp, 'latency_ms': 60, 'source': source},
    'custom': nodes.isEmpty ? null : {'nodes': nodes, 'checked_at': 1},
    'busy': busy,
  });

  /// 在带本地化的 MaterialApp 里拿到 l10n 后执行 [body]
  Future<void> withL10n(
    WidgetTester tester,
    void Function(AppLocalizations l10n) body,
  ) async {
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocaleUtils.supportedLocales,
          home: Builder(
            builder: (context) {
              body(context.l10n);
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );
  }

  group('DohSelectStatus 的自定义节点', () {
    test('解析 custom.nodes 与 busy；旧版原生库没有这两项时为空', () {
      final parsed = status(
        winnerIp: '104.18.0.9',
        source: 'custom',
        busy: true,
        nodes: [
          node(
            '104.18.0.9',
            'ok',
            ip: '104.18.0.9',
            latencyMs: 60,
            active: true,
          ),
          node('172.67.0.9', 'failed', ip: '172.67.0.9', detail: 'tcp_timeout'),
          node('1.2.3.4', 'not_cloudflare'),
        ],
      );
      expect(parsed.winnerIsCustom, isTrue);
      expect(parsed.busy, isTrue);
      expect(parsed.customNodes, hasLength(3));
      expect(parsed.customNodes[0].isOk, isTrue);
      expect(parsed.customNodes[0].active, isTrue);
      expect(parsed.customNodes[0].latencyMs, 60);
      expect(parsed.customNodes[1].detail, 'tcp_timeout');
      expect(parsed.customNodes[2].state, 'not_cloudflare');
      expect(parsed.customNodes[2].ip, isNull);

      final old = DohSelectStatus.fromJson({
        'mode': 'local_atlas',
        'phase': 'ready',
      });
      expect(old.customNodes, isEmpty);
      expect(old.busy, isFalse);
      expect(old.winnerIsCustom, isFalse);
    });

    test('toJson 再 fromJson 不丢（isolate 回传用）', () {
      final original = status(
        winnerIp: '104.18.0.9',
        source: 'custom',
        busy: true,
        nodes: [
          node(
            'cf.example.com',
            'ok',
            ip: '104.18.0.9',
            latencyMs: 60,
            active: true,
          ),
          node('172.67.0.9', 'failed', ip: '172.67.0.9', detail: 'tls'),
        ],
      );
      final copy = DohSelectStatus.fromJson(original.toJson());
      expect(copy.busy, isTrue);
      expect(copy.winnerIsCustom, isTrue);
      expect(copy.customNodes, hasLength(2));
      expect(copy.customNodes[0].entry, 'cf.example.com');
      expect(copy.customNodes[0].ip, '104.18.0.9');
      expect(copy.customNodes[0].active, isTrue);
      expect(copy.customNodes[1].state, 'failed');
      expect(copy.customNodes[1].detail, 'tls');
    });
  });

  testWidgets('入口摘要：没填 / 在用 / 都没连上 / 只报个数', (tester) async {
    await withL10n(tester, (l10n) {
      expect(
        customNodesSummary(l10n, const [], null),
        l10n.customNodes_entryDesc,
      );
      const nodes = ['104.18.0.9', '172.67.0.9'];
      // 现在的节点就是自定义的
      expect(
        customNodesSummary(
          l10n,
          nodes,
          status(winnerIp: '104.18.0.9', source: 'custom'),
        ),
        '已填 2 个 · 正在使用',
      );
      // 都测过、没一个能用
      expect(
        customNodesSummary(
          l10n,
          nodes,
          status(
            winnerIp: '104.21.0.1',
            nodes: [
              node('104.18.0.9', 'failed', detail: 'tcp_timeout'),
              node('172.67.0.9', 'not_cloudflare'),
            ],
          ),
        ),
        '已填 2 个 · 都没连上，暂时按平常的规则优选',
      );
      // 还有没测完的、或引擎还没报：只说个数
      expect(
        customNodesSummary(
          l10n,
          nodes,
          status(
            winnerIp: '104.21.0.1',
            nodes: [
              node('104.18.0.9', 'failed', detail: 'tcp_timeout'),
              node('172.67.0.9', 'pending'),
            ],
          ),
        ),
        '已填 2 个',
      );
      expect(customNodesSummary(l10n, nodes, null), '已填 2 个');
    });
  });

  testWidgets('每条节点的状态说明', (tester) async {
    await withL10n(tester, (l10n) {
      String text(
        String entry,
        Map<String, dynamic>? raw, {
        bool busy = false,
      }) => customNodeStateText(
        l10n,
        entry: entry,
        status: raw == null
            ? null
            : DohCustomNodeStatus.listFromJson({
                'nodes': [raw],
              }).single,
        busy: busy,
      );

      expect(
        text(
          '104.18.0.9',
          node(
            '104.18.0.9',
            'ok',
            ip: '104.18.0.9',
            latencyMs: 86,
            active: true,
          ),
        ),
        '正在使用 · 86 ms',
      );
      expect(
        text(
          '104.18.0.9',
          node('104.18.0.9', 'ok', ip: '104.18.0.9', latencyMs: 120),
        ),
        '可用 · 120 ms',
      );
      // 域名：说明实际连到哪个地址
      expect(
        text(
          'cf.example.com',
          node('cf.example.com', 'ok', ip: '104.18.7.7', latencyMs: 90),
        ),
        '可用 · 90 ms · 连到 104.18.7.7',
      );
      expect(
        text('172.67.0.9', node('172.67.0.9', 'failed', detail: 'tcp_timeout')),
        '没连上（超时）',
      );
      expect(
        text(
          '172.67.0.9',
          node('172.67.0.9', 'failed', detail: 'tcp_connect_failed'),
        ),
        '没连上（连接失败）',
      );
      expect(
        text(
          '172.67.0.9',
          node('172.67.0.9', 'failed', detail: 'ech_rejected'),
        ),
        '没连上（加密握手失败）',
      );
      expect(
        text('172.67.0.9', node('172.67.0.9', 'failed', detail: 'http_403')),
        '没连上（没有正常响应）',
      );
      expect(
        text('1.2.3.4', node('1.2.3.4', 'not_cloudflare')),
        l10n.customNodes_stateNotCloudflare,
      );
      expect(
        text('2606:4700::9', node('2606:4700::9', 'no_family')),
        '当前网络没有 IPv6 出口，暂时用不上',
      );
      expect(
        text('104.18.0.9', node('104.18.0.9', 'no_family')),
        '当前网络没有 IPv4 出口，暂时用不上',
      );
      expect(
        text('104.18.0.9', node('104.18.0.9', 'demoted')),
        l10n.customNodes_stateDemoted,
      );
      expect(
        text('cf.example.com', node('cf.example.com', 'unresolved')),
        l10n.customNodes_stateUnresolved,
      );
      // 还没结论：引擎在忙就是「正在测试」，否则「等待测试」
      expect(text('104.18.0.9', null, busy: true), '正在测试…');
      expect(text('104.18.0.9', null), '等待测试');
      expect(
        text('104.18.0.9', node('104.18.0.9', 'pending'), busy: true),
        '正在测试…',
      );
      expect(text('104.18.0.9', node('104.18.0.9', 'pending')), '等待测试');
    });
  });

  group('添加节点对话框', () {
    Future<List<Object?>> openDialog(
      WidgetTester tester, {
      List<String> existing = const [],
    }) async {
      // 对话框的返回值：还没关时为空，关了之后是一个元素（取消为 null）
      final results = <Object?>[];
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            locale: const Locale('zh'),
            localizationsDelegates: const [
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            supportedLocales: AppLocaleUtils.supportedLocales,
            home: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  results.add(
                    await showDialog<List<String>>(
                      context: context,
                      builder: (_) => CustomNodesAddDialog(existing: existing),
                    ),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      return results;
    }

    Future<void> submit(WidgetTester tester, String input) async {
      await tester.enterText(
        find.byKey(const ValueKey('custom-nodes-input')),
        input,
      );
      await tester.tap(find.widgetWithText(FilledButton, '确定'));
      await tester.pumpAndSettle();
    }

    testWidgets('一次粘多条：规范化、去重后返回', (tester) async {
      final results = await openDialog(tester);
      await submit(tester, '104.18.0.9:443\nCF.Example.com, 104.18.0.9');
      expect(results, [
        ['104.18.0.9', 'cf.example.com'],
      ]);
      expect(find.byType(CustomNodesAddDialog), findsNothing);
    });

    testWidgets('有写错的：指出来，不关对话框；改对了再确定', (tester) async {
      final results = await openDialog(tester);
      await submit(tester, '104.18.0.9, 1.2.3');
      expect(results, isEmpty);
      expect(find.text('写法不对：1.2.3'), findsOneWidget);
      await submit(tester, '104.18.0.9, 1.2.3.4');
      expect(results, [
        ['104.18.0.9', '1.2.3.4'],
      ]);
    });

    testWidgets('已经在清单里的不重复加', (tester) async {
      final results = await openDialog(tester, existing: ['104.18.0.9']);
      await submit(tester, '104.18.0.9');
      expect(results, isEmpty);
      expect(find.text('已经在清单里了'), findsOneWidget);
      await submit(tester, '104.18.0.9 172.67.0.9');
      expect(results, [
        ['172.67.0.9'],
      ]);
    });

    testWidgets('超过上限：说还能加几个', (tester) async {
      final existing = [
        for (var i = 1; i < CustomNodeInput.maxEntries; i++) '104.18.0.$i',
      ];
      final results = await openDialog(tester, existing: existing);
      await submit(tester, '172.67.0.1 172.67.0.2');
      expect(results, isEmpty);
      expect(
        find.text('最多 ${CustomNodeInput.maxEntries} 个，还能再加 1 个'),
        findsOneWidget,
      );
      await submit(tester, '172.67.0.1');
      expect(results, [
        ['172.67.0.1'],
      ]);
    });

    testWidgets('什么都没填就确定：当取消', (tester) async {
      final results = await openDialog(tester);
      await submit(tester, '  ');
      expect(results, [null]);
    });
  });
}
