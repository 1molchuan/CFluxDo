import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/recommended_font_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 推荐字体：清单解析、下载校验（多镜像依次尝试、tgz 抽成员）、删除。
/// 网络用本机 HttpServer 模拟镜像，字体内容是任意字节。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // flutter_test 默认把所有 HttpClient 换成固定回 400 的假客户端，这里要连本机镜像
  setUpAll(() => HttpOverrides.global = null);

  final fontBytes = List<int>.generate(4096, (i) => (i * 31 + 7) & 0xff);
  final fontSha = sha256.convert(fontBytes).toString();

  late HttpServer server;
  late Directory dir;
  var badHits = 0;

  String url(String path) => 'https://unused.invalid$path';

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    dir = await Directory.systemTemp.createTemp('recfont_');
    badHits = 0;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      switch (req.uri.path) {
        case '/font.ttf':
          req.response.headers.contentLength = fontBytes.length;
          req.response.add(fontBytes);
        case '/bad.ttf':
          badHits++;
          req.response.add(fontBytes.sublist(0, 100));
        case '/pkg.tgz':
          final archive = Archive()
            ..addFile(ArchiveFile('package/README.md', 5, utf8.encode('hello')))
            ..addFile(
              ArchiveFile('package/400Regular/Font.ttf', fontBytes.length, fontBytes),
            );
          final tgz = GZipEncoder().encode(TarEncoder().encode(archive));
          req.response.headers.contentLength = tgz.length;
          req.response.add(tgz);
        default:
          req.response.statusCode = 404;
      }
      await req.response.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  String local(String path) => 'http://127.0.0.1:${server.port}$path';

  RecommendedFontService make(String manifest) => RecommendedFontService(
    directoryProvider: () async => dir,
    dioFactory: () => Dio(),
    builtinManifestLoader: () async => manifest,
    remoteManifestLoader: () async => null,
  );

  String manifestWith(List<Object> urls, {String sha = '', int size = 0}) =>
      jsonEncode({
        'version': 1,
        'fonts': [
          {
            'id': 'demo',
            'name': '演示',
            'nameEn': 'Demo',
            'license': 'OFL-1.1',
            'file': 'Demo.ttf',
            'size': size,
            'sha256': sha,
            'urls': urls,
          },
        ],
      });

  group('清单解析', () {
    test('只收合法项：id 小写、文件 ttf/otf、至少一个 https 来源；重复 id 丢弃', () {
      final m = RecommendedFontManifest.parse(
        jsonEncode({
          'version': 3,
          'fonts': [
            {'id': 'ok', 'name': 'A', 'file': 'a.ttf', 'urls': [url('/a.ttf')]},
            {'id': 'ok', 'name': 'dup', 'file': 'a.ttf', 'urls': [url('/a.ttf')]},
            {'id': 'Bad Id', 'file': 'a.ttf', 'urls': [url('/a.ttf')]},
            {'id': 'woff', 'file': 'a.woff2', 'urls': [url('/a.woff2')]},
            {'id': 'http', 'file': 'a.ttf', 'urls': ['http://x.test/a.ttf']},
            {'id': 'loop', 'file': 'a.ttf', 'urls': ['http://127.0.0.1:1/a.ttf']},
            {
              'id': 'tgz',
              'file': 'b.otf',
              'urls': [
                {'url': url('/b.tgz'), 'tgz': 'package/b.otf'},
                url('/b.otf'),
              ],
            },
          ],
        }),
      )!;
      expect(m.version, 3);
      expect(m.fonts.map((f) => f.id), ['ok', 'loop', 'tgz']);
      expect(m.fonts.last.sources.first.tgzMember, 'package/b.otf');
      expect(m.fonts.last.sources.last.tgzMember, isNull);
    });

    test('不是对象 / 坏 JSON 返回 null', () {
      expect(RecommendedFontManifest.parse('[]'), isNull);
      expect(RecommendedFontManifest.parse('{not json'), isNull);
    });

    test('内置清单文件本身能解析，每项都有 sha256、大小与至少一个来源', () {
      final text = File('assets/fonts/recommended_fonts.json').readAsStringSync();
      final m = RecommendedFontManifest.parse(text)!;
      expect(m.fonts, isNotEmpty);
      for (final f in m.fonts) {
        expect(f.sha256.length, 64, reason: f.id);
        expect(f.size, greaterThan(0), reason: f.id);
        expect(f.sources, isNotEmpty, reason: f.id);
        expect(f.license, 'OFL-1.1', reason: f.id);
      }
    });
  });

  group('下载', () {
    test('第一个镜像坏掉（内容不对）→ 换下一个，校验通过后落盘并标记已安装', () async {
      final service = make(
        manifestWith([local('/bad.ttf'), local('/font.ttf')], sha: fontSha, size: fontBytes.length),
      );
      await service.ensureLoaded();
      final font = service.fonts.single;
      expect(service.isInstalled('demo'), isFalse);

      final path = await service.download(font);

      expect(badHits, 1);
      expect(path, '${dir.path}/demo.ttf');
      expect(File(path).readAsBytesSync(), fontBytes);
      expect(service.isInstalled('demo'), isTrue);
      expect(service.installedPath(font), path);
      expect(service.progressOf('demo'), isNull);
      expect(Directory(dir.path).listSync().map((e) => e.path.split('/').last), ['demo.ttf']);
    });

    test('tgz 来源：抽出指定成员再校验', () async {
      final service = make(
        manifestWith(
          [
            {'url': local('/pkg.tgz'), 'tgz': 'package/400Regular/Font.ttf'},
          ],
          sha: fontSha,
          size: fontBytes.length,
        ),
      );
      await service.ensureLoaded();
      final path = await service.download(service.fonts.single);
      expect(File(path).readAsBytesSync(), fontBytes);
      expect(File('$path.tgz.part').existsSync(), isFalse);
    });

    test('所有镜像都失败 → 抛出，记录错误，不留残留文件', () async {
      final service = make(manifestWith([local('/missing.ttf'), local('/bad.ttf')], sha: fontSha));
      await service.ensureLoaded();
      await expectLater(service.download(service.fonts.single), throwsA(anything));
      expect(service.isInstalled('demo'), isFalse);
      expect(service.progressOf('demo')?.error, isNotNull);
      expect(Directory(dir.path).listSync(), isEmpty);
    });

    test('删除后不再算已安装', () async {
      final service = make(manifestWith([local('/font.ttf')], sha: fontSha));
      await service.ensureLoaded();
      final font = service.fonts.single;
      final path = await service.download(font);
      await service.remove(font);
      expect(File(path).existsSync(), isFalse);
      expect(service.isInstalled('demo'), isFalse);
    });

    test('重新载入时按大小识别已安装文件，半截文件不算', () async {
      File('${dir.path}/demo.ttf').writeAsBytesSync(fontBytes.sublist(0, 10));
      final service = make(manifestWith([local('/font.ttf')], sha: fontSha, size: fontBytes.length));
      await service.ensureLoaded();
      expect(service.isInstalled('demo'), isFalse);
      File('${dir.path}/demo.ttf').writeAsBytesSync(fontBytes);
      final again = make(manifestWith([local('/font.ttf')], sha: fontSha, size: fontBytes.length));
      await again.ensureLoaded();
      expect(again.isInstalled('demo'), isTrue);
    });
  });

  test('verifyFile：大小或 sha256 不符都抛 FormatException', () async {
    final f = File('${dir.path}/v.ttf')..writeAsBytesSync(fontBytes);
    await RecommendedFontService.verifyFile(f, expectedSize: fontBytes.length, sha256Hex: fontSha);
    await expectLater(
      RecommendedFontService.verifyFile(f, expectedSize: 1, sha256Hex: ''),
      throwsA(isA<FormatException>()),
    );
    await expectLater(
      RecommendedFontService.verifyFile(f, expectedSize: 0, sha256Hex: 'ab' * 32),
      throwsA(isA<FormatException>()),
    );
  });
}
