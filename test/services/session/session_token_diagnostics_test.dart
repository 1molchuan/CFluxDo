import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/log/log_writer.dart';
import 'package:fluxdo/services/session/session_token_diagnostics.dart';

/// 切站 / 启动 / 切账号 / 被动登出时记两站两端 `_t` 摘要（2026-11 佬友日志：
/// 切到别的站待 10 小时再回来账号失效，旧日志分不清是哪一边先变的）
void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('session_tokens_');
    await LogWriter.resetForTesting();
    await LogWriter.initForTesting(dir);
  });

  tearDown(() async {
    SessionTokenDiagnostics.resetSnapshotForTesting();
    await LogWriter.resetForTesting();
    await dir.delete(recursive: true);
  });

  Future<List<Map<String, dynamic>>> entries() async {
    await LogWriter.instance.flushNow();
    final file = await LogWriter.getLogFile();
    if (!await file.exists()) return const [];
    return [
      for (final line in await file.readAsLines())
        if (line.trim().isNotEmpty) jsonDecode(line) as Map<String, dynamic>,
    ].where((e) => e['event'] == 'session_tokens').toList();
  }

  test('记下原因、附加字段和各站点两端的摘要', () async {
    SessionTokenDiagnostics.snapshotOverride = () async => {
      'linux.do': {'jarTHash': 'aaa', 'webViewTHash': 'bbb', 'same': false},
      'idcflare.com': {'jarTHash': null, 'webViewTHash': null, 'same': false},
    };
    await SessionTokenDiagnostics.log(
      'site_switch',
      extra: {'target': 'idcflare.com'},
    );
    final logged = await entries();
    expect(logged, hasLength(1));
    expect(logged.single['reason'], 'site_switch');
    expect(logged.single['target'], 'idcflare.com');
    expect(logged.single['sites']['linux.do']['webViewTHash'], 'bbb');
    expect(logged.single['sites']['linux.do']['same'], isFalse);
  });

  test('读 cookie 卡住：到时间就放弃，不拖住切站和登出', () async {
    final never = Completer<Map<String, Object?>>();
    SessionTokenDiagnostics.snapshotOverride = () => never.future;
    final watch = Stopwatch()..start();
    await SessionTokenDiagnostics.log(
      'passive_logout',
      timeout: const Duration(milliseconds: 50),
    );
    expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
    expect(await entries(), isEmpty);
  });

  test('读 cookie 出错：不抛，也不记半截', () async {
    SessionTokenDiagnostics.snapshotOverride = () async =>
        throw StateError('cookie manager gone');
    await SessionTokenDiagnostics.log('app_start');
    expect(await entries(), isEmpty);
  });
}
