import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/apk_download_service.dart';
import 'package:fluxdo/services/update/github_mirror_policy.dart';
import 'package:fluxdo/services/update/mirrored_apk_downloader.dart';
import 'package:fluxdo/services/update_service.dart';

/// 应用内更新下载自动选线（2026-11 佬友：国内直连 GitHub 下载卡 0% 后失败）
void main() {
  late HttpServer server;
  late String base;
  late Uint8List apk;
  late String apkSha;
  late Directory tmp;
  final rangeRequests = <String, List<String?>>{};

  Future<void> serveRange(
    HttpRequest req,
    Uint8List body, {
    bool honourRange = true,
  }) async {
    final res = req.response;
    final range = req.headers.value('range');
    var start = 0;
    final match = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(range ?? '');
    if (honourRange && match != null) {
      start = int.parse(match.group(1)!);
      final end = match.group(2)!.isEmpty
          ? body.length - 1
          : min(int.parse(match.group(2)!), body.length - 1);
      res.statusCode = HttpStatus.partialContent;
      res.headers.set('content-range', 'bytes $start-$end/${body.length}');
      res.contentLength = end - start + 1;
      res.add(body.sublist(start, end + 1));
    } else {
      res.contentLength = body.length;
      res.add(body);
    }
    await res.close();
  }

  setUp(() async {
    final random = Random(42);
    apk = Uint8List.fromList([
      0x50,
      0x4B,
      0x03,
      0x04,
      ...List.generate(300 * 1024, (_) => random.nextInt(256)),
    ]);
    apkSha = sha256.convert(apk).toString();
    tmp = await Directory.systemTemp.createTemp('apk_mirror_');
    rangeRequests.clear();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://127.0.0.1:${server.port}';
    server.listen((req) async {
      final kind = req.uri.pathSegments.first;
      (rangeRequests[kind] ??= []).add(req.headers.value('range'));
      final res = req.response;
      switch (kind) {
        case 'good':
        case 'good2':
          await serveRange(req, apk);
        case 'slowstart':
          await Future<void>.delayed(const Duration(milliseconds: 400));
          await serveRange(req, apk);
        case 'norange':
          await serveRange(req, apk, honourRange: false);
        case 'html':
          res.headers.contentType = ContentType.html;
          res.write('<!doctype html><title>mirror error</title>');
          await res.close();
        case 'dead':
          res.statusCode = 502;
          await res.close();
        case 'evil':
          final bad = Uint8List.fromList(apk)..[1000] ^= 0xFF;
          await serveRange(req, bad);
        case 'stall':
          // 先给一段真数据，然后一直不动
          final range = req.headers.value('range');
          res.statusCode = range == null ? 200 : HttpStatus.partialContent;
          if (range != null) {
            res.headers.set(
              'content-range',
              'bytes 0-${apk.length - 1}/${apk.length}',
            );
          }
          res.contentLength = apk.length;
          res.add(apk.sublist(0, 100 * 1024));
          await res.flush();
          await Future<void>.delayed(const Duration(seconds: 30));
          try {
            await res.close();
          } catch (_) {}
        case 'trickle':
          res.statusCode = 200;
          res.contentLength = apk.length;
          // 每 300 ms 8 KB（约 27 KB/s）：一直有数据（不算卡住），但慢
          const chunk = 8 * 1024;
          for (var i = 0; i < 20; i++) {
            try {
              res.add(apk.sublist(i * chunk, (i + 1) * chunk));
              await res.flush();
            } catch (_) {
              return;
            }
            await Future<void>.delayed(const Duration(milliseconds: 300));
          }
          try {
            await res.close();
          } catch (_) {}
      }
    });
  });

  tearDown(() async {
    await server.close(force: true);
    await tmp.delete(recursive: true);
  });

  DownloadRoute route(
    String kind, {
    bool official = false,
    bool user = false,
  }) => DownloadRoute(
    label: kind,
    url: '$base/$kind/app.apk',
    official: official,
    userConfigured: user,
  );

  MirroredApkDownloader downloader() => MirroredApkDownloader(
    dio: Dio(),
    probeTimeout: const Duration(seconds: 2),
    stallTimeout: const Duration(milliseconds: 600),
    slowWindow: const Duration(milliseconds: 1500),
    slowBytesPerSecond: 50 * 1024,
  );

  group('线路列表', () {
    const original =
        'https://github.com/1molchuan/CFluxDo/releases/download/1.3.4/cfluxdo-1.3.4-arm64-v8a.apk';

    test('用户填的反代在最前，然后官方直连，再是公共镜像', () {
      final routes = GithubMirrorPolicy.routes(
        original,
        userProxy: 'https://my.proxy.example',
      );
      expect(routes.first.url, 'https://my.proxy.example/$original');
      expect(routes.first.userConfigured, isTrue);
      expect(routes[1].url, original);
      expect(routes[1].official, isTrue);
      expect(
        routes.map((r) => r.url),
        contains('https://ghfast.top/$original'),
      );
      expect(
        routes.map((r) => r.url),
        contains(
          'https://xget.xi-xu.me/gh/1molchuan/CFluxDo/releases/download/1.3.4/cfluxdo-1.3.4-arm64-v8a.apk',
        ),
      );
      expect(routes.map((r) => r.url).toSet(), hasLength(routes.length));
    });

    test('拿不到可信校验值时不用公共镜像', () {
      final routes = GithubMirrorPolicy.routes(
        original,
        userProxy: 'https://my.proxy.example/',
        allowPublicMirrors: false,
      );
      expect(routes.map((r) => r.label), ['my.proxy.example', 'github.com']);
    });

    test('用户填的就是内置镜像时不重复', () {
      final routes = GithubMirrorPolicy.routes(
        original,
        userProxy: 'https://ghfast.top/',
      );
      expect(routes.where((r) => r.label == 'ghfast.top'), hasLength(1));
      expect(routes.first.userConfigured, isTrue);
    });

    test('不是 GitHub 的链接只有它自己', () {
      final routes = GithubMirrorPolicy.routes('https://example.com/a.apk');
      expect(routes.map((r) => r.url), ['https://example.com/a.apk']);
    });

    test('GitHub 接口的 digest 解析成小写十六进制', () {
      final hex = 'AB' * 32;
      expect(UpdateService.sha256OfDigest('sha256:$hex'), hex.toLowerCase());
      expect(UpdateService.sha256OfDigest('sha512:$hex'), isNull);
      expect(UpdateService.sha256OfDigest(null), isNull);
      expect(UpdateService.sha256OfDigest('sha256:abc'), isNull);
    });

    test('ApkAsset 的 sha256 跟着缓存存取', () {
      final asset = ApkAsset(
        downloadUrl: 'https://github.com/a/b/releases/download/1/x.apk',
        sha256: 'ff' * 32,
        architecture: 'arm64-v8a',
        size: 1,
        name: 'x.apk',
      );
      expect(ApkAsset.fromJson(asset.toJson()).sha256, 'ff' * 32);
      expect(
        ApkAsset.fromJson({...asset.toJson()}..remove('sha256')).sha256,
        isNull,
      );
    });
  });

  group('测速', () {
    test('回网页、502 的公共镜像剔掉；通的按快慢排；不通的官方直连留着兜底', () async {
      final results = await downloader().probe([
        route('dead', official: true),
        route('slowstart'),
        route('html'),
        route('good'),
        route('dead'),
      ]);
      expect(
        {for (final r in results) r.route.label: r.ok},
        {'dead': false, 'slowstart': true, 'html': false, 'good': true},
      );
      final ranked = MirroredApkDownloader.rank(results);
      expect(ranked.map((r) => r.label), ['good', 'slowstart', 'dead']);
      expect(ranked.last.official, isTrue);
    });

    test('测速只拉一小段', () async {
      await downloader().probe([route('good')]);
      expect(rangeRequests['good'], ['bytes=0-131071']);
    });
  });

  group('下载', () {
    test('一条线就下完并核对', () async {
      final file = await downloader().download(
        routes: [route('good')],
        target: File('${tmp.path}/a.apk'),
        expectedSize: apk.length,
        expectedSha256: apkSha,
      );
      expect(await file.readAsBytes(), apk);
      expect(await File('${file.path}.part').exists(), isFalse);
    });

    test('卡住就换下一条，并从断点接着下', () async {
      final events = <MirrorDownloadEvent>[];
      final file = await downloader().download(
        routes: [route('stall'), route('good')],
        target: File('${tmp.path}/a.apk'),
        expectedSize: apk.length,
        expectedSha256: apkSha,
        onEvent: events.add,
      );
      expect(await file.readAsBytes(), apk);
      // 第二条线是从 100 KB 处接着要的
      expect(rangeRequests['good'], ['bytes=${100 * 1024}-']);
      final switched = events.whereType<MirrorRouteSelected>().last;
      expect(switched.route.label, 'good');
      expect(switched.previous?.label, 'stall');
      expect(switched.reason, MirrorSwitchReason.stalled);
    });

    test('太慢且还有别的线路就换', () async {
      final events = <MirrorDownloadEvent>[];
      await downloader().download(
        routes: [route('trickle'), route('good')],
        target: File('${tmp.path}/a.apk'),
        expectedSize: apk.length,
        expectedSha256: apkSha,
        onEvent: events.add,
      );
      final switched = events.whereType<MirrorRouteSelected>().last;
      expect(switched.previous?.label, 'trickle');
      expect(switched.reason, MirrorSwitchReason.slow);
    });

    test('回网页的线路跳过，不把已下的部分清掉', () async {
      // stall 先下 100 KB → html 不是 APK（206 续传时不查开头，它回 200 网页）→ good 接着下
      final file = await downloader().download(
        routes: [route('stall'), route('html'), route('good')],
        target: File('${tmp.path}/a.apk'),
        expectedSize: apk.length,
        expectedSha256: apkSha,
      );
      expect(await file.readAsBytes(), apk);
      expect(rangeRequests['good'], ['bytes=${100 * 1024}-']);
    });

    test('服务端不认 Range 就从头下', () async {
      final file = await downloader().download(
        routes: [route('stall'), route('norange')],
        target: File('${tmp.path}/a.apk'),
        expectedSize: apk.length,
        expectedSha256: apkSha,
      );
      expect(await file.readAsBytes(), apk);
    });

    test('内容被改过：剔掉出过力的公共镜像重下一遍', () async {
      final file = await downloader().download(
        routes: [route('evil'), route('good', official: true)],
        target: File('${tmp.path}/a.apk'),
        expectedSize: apk.length,
        expectedSha256: apkSha,
      );
      expect(await file.readAsBytes(), apk);
      expect(rangeRequests['evil'], hasLength(1));
    });

    test('只有被改过的线路：报校验失败，不留文件', () async {
      await expectLater(
        downloader().download(
          routes: [route('evil')],
          target: File('${tmp.path}/a.apk'),
          expectedSize: apk.length,
          expectedSha256: apkSha,
        ),
        throwsA(
          isA<MirrorDownloadException>().having(
            (e) => e.kind,
            'kind',
            MirrorDownloadFailure.checksumMismatch,
          ),
        ),
      );
      expect(await File('${tmp.path}/a.apk').exists(), isFalse);
      expect(await File('${tmp.path}/a.apk.part').exists(), isFalse);
    });

    test('全都不通：报所有线路失败', () async {
      await expectLater(
        downloader().download(
          routes: [route('dead'), route('html')],
          target: File('${tmp.path}/a.apk'),
          expectedSize: apk.length,
          expectedSha256: apkSha,
        ),
        throwsA(
          isA<MirrorDownloadException>().having(
            (e) => e.kind,
            'kind',
            MirrorDownloadFailure.allRoutesFailed,
          ),
        ),
      );
    });

    test('取消：报取消，不再换线', () async {
      final cancel = CancelToken();
      final future = downloader().download(
        routes: [route('stall'), route('good')],
        target: File('${tmp.path}/a.apk'),
        expectedSize: apk.length,
        expectedSha256: apkSha,
        cancel: cancel,
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));
      cancel.cancel();
      await expectLater(
        future,
        throwsA(
          isA<MirrorDownloadException>().having(
            (e) => e.kind,
            'kind',
            MirrorDownloadFailure.cancelled,
          ),
        ),
      );
      expect(rangeRequests['good'], isNull);
    });
  });

  test('本机临时地址只给那一个文件', () async {
    final file = File('${tmp.path}/cfluxdo-1.3.4-arm64-v8a.apk');
    await file.writeAsBytes(apk);
    final loopback = await ApkLoopbackServer.start(file);
    addTearDown(loopback.close);
    final client = HttpClient();
    addTearDown(client.close);

    Future<(int, List<int>)> get(String url) async {
      final res = await (await client.getUrl(Uri.parse(url))).close();
      final bytes = await res.fold<List<int>>([], (a, b) => a..addAll(b));
      return (res.statusCode, bytes);
    }

    final (status, body) = await get(loopback.url);
    expect(status, 200);
    expect(body, apk);
    final other = Uri.parse(loopback.url)
        .replace(path: '/x/${file.uri.pathSegments.last}');
    expect((await get(other.toString())).$1, 404);
  });
}
