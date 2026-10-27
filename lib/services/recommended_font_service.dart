import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_logger.dart';
import 'custom_font_service.dart';
import 'network/adapters/platform_adapter.dart';

/// 一个下载来源：直接的字体文件，或者一个 npm 包 tgz（取其中一个成员）。
///
/// npmmirror 对部分 scoped 包不开放单文件接口，但整包 tgz 走阿里 CDN 可下，
/// 所以国内镜像常常是「下 tgz、抽出字体」这种形式。
class RecommendedFontSource {
  const RecommendedFontSource(this.url, {this.tgzMember});

  final String url;

  /// 非空表示 [url] 是 .tgz，字体是包里这个路径的成员（如 `package/400Regular/x.ttf`）
  final String? tgzMember;

  static RecommendedFontSource? fromJson(Object? json) {
    String? url;
    String? member;
    if (json is String) {
      url = json;
    } else if (json is Map) {
      url = json['url'] as String?;
      member = json['tgz'] as String?;
    }
    final uri = url == null ? null : Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty || !_schemeAllowed(uri)) return null;
    return RecommendedFontSource(
      url!,
      tgzMember: (member == null || member.isEmpty) ? null : member,
    );
  }

  /// 只接受 https；回环地址允许 http（测试 / 本机调试用）。
  static bool _schemeAllowed(Uri uri) {
    if (uri.scheme == 'https') return true;
    if (uri.scheme != 'http') return false;
    final host = uri.host;
    return host == 'localhost' ||
        host == '127.0.0.1' ||
        host == '::1' ||
        host == '[::1]';
  }
}

/// 推荐字体清单里的一项。
///
/// 全部是可再分发的开源字体（OFL 等），文件按 [sources] 的顺序逐个镜像尝试：
/// 前面放国内可达的镜像（npmmirror / jsDelivr），GitHub Release 垫底。
/// 下载完按 [sha256] 校验，不对就当没下过，换下一个镜像再来。
class RecommendedFont {
  const RecommendedFont({
    required this.id,
    required this.name,
    required this.nameEn,
    required this.license,
    required this.fileName,
    required this.size,
    required this.sha256,
    required this.sources,
    this.preview = '永远相信美好的事情即将发生',
    this.weight = 400,
    this.domesticMirror = false,
  });

  /// 稳定的标识，也是落盘文件名的一部分
  final String id;

  /// 中文名（界面主标题）
  final String name;

  /// 英文名 / 原名
  final String nameEn;

  /// 许可证简称，如 `OFL-1.1`
  final String license;

  /// 落盘文件名（扩展名决定格式，只认 ttf / otf）
  final String fileName;

  /// 文件字节数（0 表示未知，不校验大小）
  final int size;

  /// 文件 sha256（小写十六进制），空串表示不校验
  final String sha256;

  /// 下载来源，按优先级排列
  final List<RecommendedFontSource> sources;

  /// 预览字样
  final String preview;

  /// 字重（只是展示用）
  final int weight;

  /// 是否有国内可达的镜像（界面上做个标记，没有的提示可能较慢）
  final bool domesticMirror;

  String get sizeLabel => size <= 0
      ? ''
      : '${(size / (1024 * 1024)).toStringAsFixed(1)} MB';

  static RecommendedFont? fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final fileName = json['file'];
    final urls = json['urls'];
    if (id is! String ||
        id.isEmpty ||
        !RegExp(r'^[a-z0-9-]+$').hasMatch(id) ||
        fileName is! String ||
        !CustomFontService.supportedExtensions.any(
          (ext) => fileName.toLowerCase().endsWith('.$ext'),
        ) ||
        urls is! List ||
        urls.isEmpty) {
      return null;
    }
    final sources = <RecommendedFontSource>[];
    for (final u in urls) {
      final source = RecommendedFontSource.fromJson(u);
      if (source != null) sources.add(source);
    }
    if (sources.isEmpty) return null;
    return RecommendedFont(
      id: id,
      name: json['name'] as String? ?? id,
      nameEn: json['nameEn'] as String? ?? '',
      license: json['license'] as String? ?? '',
      fileName: fileName,
      size: (json['size'] as num?)?.toInt() ?? 0,
      sha256: (json['sha256'] as String? ?? '').toLowerCase(),
      sources: sources,
      preview: json['preview'] as String? ?? '永远相信美好的事情即将发生',
      weight: (json['weight'] as num?)?.toInt() ?? 400,
      domesticMirror: json['domesticMirror'] as bool? ?? false,
    );
  }
}

/// 清单：内置一份在 assets，可被远端同结构的 JSON 覆盖（版本号更大才接受）。
class RecommendedFontManifest {
  const RecommendedFontManifest({required this.version, required this.fonts});

  final int version;
  final List<RecommendedFont> fonts;

  static RecommendedFontManifest? parse(String text) {
    try {
      final decoded = jsonDecode(text);
      if (decoded is! Map<String, dynamic>) return null;
      final version = (decoded['version'] as num?)?.toInt() ?? 0;
      final raw = decoded['fonts'];
      if (raw is! List) return null;
      final fonts = <RecommendedFont>[];
      final seen = <String>{};
      for (final item in raw) {
        if (item is! Map<String, dynamic>) continue;
        final font = RecommendedFont.fromJson(item);
        if (font == null || !seen.add(font.id)) continue;
        fonts.add(font);
      }
      return RecommendedFontManifest(version: version, fonts: fonts);
    } catch (_) {
      return null;
    }
  }
}

/// 一项的下载状态
class RecommendedFontProgress {
  const RecommendedFontProgress({this.fraction, this.error});

  /// 0~1；null 表示还不知道总大小
  final double? fraction;

  /// 最近一次失败原因（供界面提示），下载中为 null
  final String? error;
}

/// 推荐字体的下载、校验、落盘与删除。
///
/// 文件放在应用支持目录下的 `recommended_fonts/<id>.<ext>`，与用户自己导入
/// 的 `custom_fonts/` 分开管理；启用时走和自选文件一样的路（注册进引擎、
/// 作为「自定义字体」生效），所以字体选择那边不用多一种状态。
class RecommendedFontService extends ChangeNotifier {
  RecommendedFontService({
    Future<Directory> Function()? directoryProvider,
    Dio Function()? dioFactory,
    Future<String> Function()? builtinManifestLoader,
    Future<String?> Function()? remoteManifestLoader,
  }) : _directoryProvider = directoryProvider ?? _defaultDirectory,
       _dioFactory = dioFactory ?? _defaultDio,
       _builtinManifestLoader =
           builtinManifestLoader ?? (() => rootBundle.loadString(manifestAsset)),
       _remoteManifestLoader = remoteManifestLoader;

  static final RecommendedFontService instance = RecommendedFontService();

  /// 内置清单
  static const String manifestAsset = 'assets/fonts/recommended_fonts.json';

  /// 远端清单：仓库里同一个文件，经 jsDelivr 取（加镜像、换版本不用发包）
  static const String remoteManifestUrl =
      'https://cdn.jsdelivr.net/gh/1molchuan/CFluxDo@main/assets/fonts/recommended_fonts.json';

  /// 远端清单的本地缓存（SharedPreferences）
  static const String cachedManifestKey = 'recommended_fonts_manifest';

  static const String _dirName = 'recommended_fonts';

  final Future<Directory> Function() _directoryProvider;
  final Dio Function() _dioFactory;
  final Future<String> Function() _builtinManifestLoader;
  final Future<String?> Function()? _remoteManifestLoader;

  RecommendedFontManifest? _manifest;
  Future<void>? _loading;
  final Map<String, RecommendedFontProgress> _progress = {};
  final Map<String, CancelToken> _cancelTokens = {};
  final Set<String> _installed = {};
  Directory? _dir;

  List<RecommendedFont> get fonts => _manifest?.fonts ?? const [];

  bool get loaded => _manifest != null;

  bool isInstalled(String id) => _installed.contains(id);

  bool isDownloading(String id) => _cancelTokens.containsKey(id);

  RecommendedFontProgress? progressOf(String id) => _progress[id];

  /// 已安装字体的文件路径（未安装返回 null）
  String? installedPath(RecommendedFont font) {
    final dir = _dir;
    if (dir == null || !_installed.contains(font.id)) return null;
    return _filePath(dir, font);
  }

  /// 字体文件对应的 family 名（与自选字体同一套规则：由文件路径推出）
  static String familyNameFor(String path) =>
      CustomFontService.familyNameFor(path);

  /// 是否是推荐字体目录下的文件（Windows 上目录分隔符是 `\`，拼上文件名
  /// 那一段又是 `/`，两种都认）
  static bool isRecommendedFontPath(String? path) =>
      path != null && RegExp('[/\\\\]$_dirName[/\\\\]').hasMatch(path);

  /// 载入清单（内置 → 缓存的远端 → 远端刷新）并扫描已安装文件。可重复调用。
  Future<void> ensureLoaded() => _loading ??= _load();

  Future<void> _load() async {
    final builtin = RecommendedFontManifest.parse(
      await _builtinManifestLoader(),
    );
    _manifest = builtin ?? const RecommendedFontManifest(version: 0, fonts: []);
    await _scanInstalled();
    notifyListeners();

    // 远端清单：先用上次缓存的，再异步拉新；都要版本号不低于内置才接受
    try {
      final prefs = await SharedPreferences.getInstance();
      _adoptRemote(prefs.getString(cachedManifestKey));
      final loader = _remoteManifestLoader ?? _fetchRemoteManifest;
      final text = await loader();
      if (text != null && _adoptRemote(text)) {
        await prefs.setString(cachedManifestKey, text);
      }
    } catch (e) {
      debugPrint('[RecommendedFont] 远端清单不可用: $e');
    }
  }

  bool _adoptRemote(String? text) {
    if (text == null || text.isEmpty) return false;
    final remote = RecommendedFontManifest.parse(text);
    final current = _manifest;
    if (remote == null ||
        remote.fonts.isEmpty ||
        current == null ||
        remote.version < current.version) {
      return false;
    }
    _manifest = remote;
    unawaited(_scanInstalled().then((_) => notifyListeners()));
    return true;
  }

  Future<String?> _fetchRemoteManifest() async {
    final dio = _dioFactory();
    try {
      final response = await dio.get<String>(
        remoteManifestUrl,
        options: Options(
          responseType: ResponseType.plain,
          receiveTimeout: const Duration(seconds: 15),
        ),
      );
      return response.data;
    } finally {
      dio.close();
    }
  }

  Future<void> _scanInstalled() async {
    final dir = _dir ??= await _directoryProvider();
    _installed.clear();
    for (final font in fonts) {
      final file = File(_filePath(dir, font));
      if (!file.existsSync()) continue;
      final length = file.lengthSync();
      // 大小对不上就是没下完的残留，不算已安装（下次下载会覆盖）
      if (font.size > 0 && length != font.size) continue;
      if (length == 0) continue;
      _installed.add(font.id);
    }
  }

  String _filePath(Directory dir, RecommendedFont font) {
    final dot = font.fileName.lastIndexOf('.');
    final ext = dot > 0 ? font.fileName.substring(dot).toLowerCase() : '.ttf';
    return '${dir.path}/${font.id}$ext';
  }

  /// 下载并校验；成功后文件可用、[isInstalled] 为真。失败抛出异常并记录到
  /// [progressOf]（界面据此提示），各镜像依次尝试。
  Future<String> download(RecommendedFont font) async {
    if (_cancelTokens.containsKey(font.id)) {
      throw StateError('already downloading');
    }
    await ensureLoaded();
    final dir = _dir ??= await _directoryProvider();
    final target = File(_filePath(dir, font));
    final temp = File('${target.path}.part');
    final cancel = CancelToken();
    _cancelTokens[font.id] = cancel;
    _progress[font.id] = const RecommendedFontProgress(fraction: 0);
    notifyListeners();

    Object? lastError;
    try {
      for (final source in font.sources) {
        if (cancel.isCancelled) break;
        final dio = _dioFactory();
        final url = source.url;
        final member = source.tgzMember;
        // tgz 先落到另一个临时文件，抽出成员后再写成 .part
        final downloadTarget = member == null
            ? temp
            : File('${target.path}.tgz.part');
        try {
          if (temp.existsSync()) temp.deleteSync();
          if (downloadTarget.existsSync()) downloadTarget.deleteSync();
          await dio.download(
            url,
            downloadTarget.path,
            cancelToken: cancel,
            options: Options(
              receiveTimeout: const Duration(seconds: 60),
              headers: const {'Accept': 'application/octet-stream, */*'},
            ),
            onReceiveProgress: (received, total) {
              // tgz 的总长度不等于字体大小，只在服务端给了 content-length 时算进度
              final denominator = total > 0 ? total : (member == null ? font.size : 0);
              _progress[font.id] = RecommendedFontProgress(
                fraction: denominator > 0
                    ? (received / denominator).clamp(0.0, 1.0)
                    : null,
              );
              notifyListeners();
            },
          );
          if (member != null) {
            await extractTgzMember(downloadTarget, member, temp);
            try {
              downloadTarget.deleteSync();
            } catch (_) {}
          }
          await verifyFile(temp, expectedSize: font.size, sha256Hex: font.sha256);
          if (target.existsSync()) target.deleteSync();
          temp.renameSync(target.path);
          _installed.add(font.id);
          _progress.remove(font.id);
          AppLogger.info(
            '推荐字体下载完成',
            tag: 'RecommendedFont',
            fields: {'id': font.id, 'url': url, 'bytes': target.lengthSync()},
          );
          return target.path;
        } on DioException catch (e) {
          if (CancelToken.isCancel(e)) {
            lastError = e;
            break;
          }
          lastError = e;
          debugPrint('[RecommendedFont] ${font.id} 镜像失败 $url: ${e.type}');
        } catch (e) {
          lastError = e;
          debugPrint('[RecommendedFont] ${font.id} 镜像失败 $url: $e');
        } finally {
          dio.close();
          if (downloadTarget != temp && downloadTarget.existsSync()) {
            try {
              downloadTarget.deleteSync();
            } catch (_) {}
          }
        }
      }
      if (temp.existsSync()) {
        try {
          temp.deleteSync();
        } catch (_) {}
      }
      final cancelled = cancel.isCancelled;
      _progress[font.id] = RecommendedFontProgress(
        error: cancelled ? null : (lastError?.toString() ?? 'no mirror'),
      );
      if (!cancelled) {
        AppLogger.warning(
          '推荐字体下载失败',
          tag: 'RecommendedFont',
          fields: {'id': font.id, 'error': lastError.toString()},
        );
      }
      throw lastError ?? StateError('no mirror');
    } finally {
      _cancelTokens.remove(font.id);
      notifyListeners();
    }
  }

  /// 取消进行中的下载（没有在下就什么都不做）
  void cancel(String id) {
    _cancelTokens[id]?.cancel('user');
  }

  /// 删除已下载的字体文件
  Future<void> remove(RecommendedFont font) async {
    final dir = _dir ??= await _directoryProvider();
    final file = File(_filePath(dir, font));
    try {
      if (file.existsSync()) await file.delete();
    } on FileSystemException {
      // 删不掉就留着，不影响主流程
    }
    _installed.remove(font.id);
    _progress.remove(font.id);
    notifyListeners();
  }

  /// 从 npm 包 tgz 里抽出一个成员写到 [out]。找不到成员抛 [FormatException]。
  /// 整包十几 MB，直接读进内存解（compute 里跑，别卡 UI）。
  @visibleForTesting
  static Future<void> extractTgzMember(
    File tgz,
    String member,
    File out,
  ) async {
    final bytes = await tgz.readAsBytes();
    final content = await compute(_extractMember, (bytes, member));
    if (content == null) {
      throw FormatException('tgz member not found: $member');
    }
    await out.writeAsBytes(content, flush: true);
  }

  static Uint8List? _extractMember((Uint8List, String) args) {
    final (bytes, member) = args;
    final tar = TarDecoder().decodeBytes(GZipDecoder().decodeBytes(bytes));
    final wanted = member.startsWith('/') ? member.substring(1) : member;
    for (final file in tar.files) {
      if (!file.isFile) continue;
      final name = file.name.startsWith('/') ? file.name.substring(1) : file.name;
      if (name == wanted) {
        return Uint8List.fromList(file.content as List<int>);
      }
    }
    return null;
  }

  /// 校验下载结果：大小（已知时）与 sha256（给了时）。不符抛 [FormatException]。
  @visibleForTesting
  static Future<void> verifyFile(
    File file, {
    required int expectedSize,
    required String sha256Hex,
  }) async {
    if (!file.existsSync()) throw const FormatException('file missing');
    final length = file.lengthSync();
    if (length == 0) throw const FormatException('empty file');
    if (expectedSize > 0 && length != expectedSize) {
      throw FormatException('size mismatch: $length != $expectedSize');
    }
    if (sha256Hex.isNotEmpty) {
      final digest = await sha256.bind(file.openRead()).first;
      if (digest.toString() != sha256Hex) {
        throw const FormatException('sha256 mismatch');
      }
    }
  }

  static Future<Directory> _defaultDirectory() async {
    final support = await getApplicationSupportDirectory();
    final dir = Directory('${support.path}/$_dirName');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  /// 外部下载走应用的网络配置（系统代理 / 自定义代理照常生效），不带站点 cookie
  static Dio _defaultDio() {
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 20),
        followRedirects: true,
        maxRedirects: 5,
      ),
    );
    dio.httpClientAdapter = createExternalHttpAdapter();
    return dio;
  }
}
