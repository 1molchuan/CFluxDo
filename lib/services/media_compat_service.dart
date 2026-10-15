import 'dart:async';
import 'dart:convert' show utf8;
import 'dart:io';
import 'dart:typed_data' show BytesBuilder, Uint8List;

import 'package:crypto/crypto.dart' show sha1;
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:mime/mime.dart';
import 'package:path_provider/path_provider.dart';

import 'network/discourse_dio.dart';
import '../utils/webm_opus_to_caf.dart';

/// 「改名上传」媒体兼容服务。
///
/// linux.do 等站点用扩展名白名单限制上传类型,用户常把 mp4/mp3 改后缀
/// (如 `.xz`)绕过 —— 文件内容是合法媒体,但 URL 扩展名与 CDN 返回的
/// Content-Type(application/x-xz + attachment)全是错的。
///
/// 播放器差异:浏览器 `<video>` 与 ExoPlayer(Android)按**内容**嗅探
/// 容器,直接能播;AVFoundation(iOS/macOS)按扩展名/Content-Type 认
/// 容器,直接拒(OSStatus -12847「media format is not supported」)。
///
/// 修法:对「扩展名不是已知 video/audio 类型」的源,Range 抓头部字节
/// → mime 包魔数嗅探 → 确认是媒体后整文件下载到本地、以**正确扩展名**
/// 命名,返回 file:// 给播放器(AVFoundation 对本地文件按扩展名解码,
/// 即恢复正常)。嗅探/下载任何一步失败都原样返回,让播放器自身的错误
/// 链路兜底。
///
/// 触发条件完全由数据派生(URL 扩展名映射不到媒体 mime 才探测),不做
/// 站点/后缀白名单;普通 .mp4/.mp3 源零开销直通。
class MediaCompatService {
  MediaCompatService._();

  static final MediaCompatService instance = MediaCompatService._();

  /// 测试用平台开关:覆盖「是否 AVFoundation 平台」判定。
  @visibleForTesting
  static bool? debugAvPlatformOverride;

  static const _dirName = 'media_compat';

  /// 嗅探读取的头部字节数(魔数表最长 12 字节,留足余量)。
  static const _sniffBytes = 512;

  /// 本地化大小上限:头响应报告超过此值直接放弃(防磁盘/流量失控)。
  static const _maxLocalizeBytes = 1 << 30; // 1 GiB

  /// 懒建 Dio:cookie 开着走 secure-uploads(CDN host 无 cookie 自然不带),
  /// 媒体文件下载不需要 CF 验证/重试/日志。测试只用纯函数,不会触发构建。
  late final Dio _dio = DiscourseDio.create(
    kind: DiscourseDioKind.media,
    enableCookies: true,
  );

  /// url → 播放地址(含负缓存:确认非媒体/无需处理时缓存原 URL,
  /// 避免滚动重建反复发嗅探请求)。仅缓存确定性结果,网络失败不缓存。
  final Map<String, String> _resolved = {};
  final Map<String, Future<String>> _inflight = {};

  Future<Directory>? _dirFuture;
  bool _swept = false;

  /// 是否需要探测:仅 AVFoundation 平台(iOS/macOS)+ http(s) URL +
  /// 扩展名映射不到 video/audio mime 时为 true。
  ///
  /// Android(ExoPlayer)/web(浏览器)按内容嗅探无需处理;
  /// Windows/Linux 当前无 video_player 后端,处理了也没有播放器可用。
  bool needsProbe(String url) {
    final isAvPlatform = debugAvPlatformOverride ??
        (!kIsWeb && (Platform.isIOS || Platform.isMacOS));
    if (!isAvPlatform) return false;
    final uri = Uri.tryParse(url);
    if (uri == null || (!uri.isScheme('http') && !uri.isScheme('https'))) {
      return false;
    }
    return !_isMediaMime(lookupMimeType(uri.path));
  }

  /// 已完成的解析结果(含负缓存),build 里同步短路用。
  String? cachedPlayableUrl(String url) => _resolved[url];

  /// 把可能改过扩展名的媒体 URL 解析成可播放地址。
  ///
  /// [needsProbe] 为 false 时原样返回;否则嗅探 + 本地化,返回 file://。
  /// 全链路不抛异常,失败一律回退原 URL。
  Future<String> resolvePlayableUrl(String url) {
    if (!needsProbe(url)) return Future.value(url);
    final cached = _resolved[url];
    if (cached != null) return Future.value(cached);
    return _inflight[url] ??= _resolve(url).whenComplete(() {
      _inflight.remove(url);
    });
  }

  Future<String> _resolve(String url) async {
    try {
      final head = await _fetchHead(url);
      if (head == null) return url; // 头都拿不到/过大:不缓存,下次再试
      final mime = sniffMime(url, head);
      if (!_isMediaMime(mime)) {
        // 确定性结论:内容确实不是媒体,负缓存防滚动重建反复嗅探
        return _resolved[url] = url;
      }
      // EBML(webm/mkv)容器:AVFoundation 不认,改扩展名也没用。纯 Opus
      // 音轨(Discourse 录音消息的标准形态)可无损重封装成 CAF ——
      // CoreAudio 认 CAF 内 Opus,afplay 已实证;webm 视频 / vorbis 无解,
      // 负缓存原 URL 走播放器错误链兜底。
      if (mime == 'audio/weba') {
        final caf = await _remuxWebmOpusToCaf(url);
        return _resolved[url] =
            caf != null ? Uri.file(caf.path).toString() : url;
      }
      final file = await _localize(url, extensionForMimeType(mime!));
      return _resolved[url] = Uri.file(file.path).toString();
    } catch (e) {
      debugPrint('[MediaCompat] 兼容处理失败,回退原 URL: $url, error=$e');
      return url;
    }
  }

  static bool _isMediaMime(String? mime) =>
      mime != null && (mime.startsWith('video/') || mime.startsWith('audio/'));

  /// 魔数嗅探真实 mime。
  ///
  /// mime 包 magic 表覆盖 mp4 主流 brand(isom/iso2/avc1/mp41/mp42)与
  /// mp3(ID3/0xFFFB)/aac/wav/flac/ogg/webm 等;ISO-BMFF 其余 brand
  /// (qt/M4A/3gp 系)不在表内,按 `....ftyp` 容器结构补判。
  @visibleForTesting
  static String? sniffMime(String url, Uint8List head) {
    final path = Uri.tryParse(url)?.path ?? url;
    final byMagic = lookupMimeType(path, headerBytes: head);
    if (_isMediaMime(byMagic)) return byMagic;
    // ISO-BMFF:bytes[4..8) == 'ftyp',major brand 在 [8..12)
    if (head.length >= 12 &&
        head[4] == 0x66 &&
        head[5] == 0x74 &&
        head[6] == 0x79 &&
        head[7] == 0x70) {
      final brand = String.fromCharCodes(head.sublist(8, 12));
      if (brand.startsWith('qt')) return 'video/quicktime';
      if (brand.startsWith('M4A')) return 'audio/mp4';
      if (brand.startsWith('3g')) return 'video/3gpp';
      return 'video/mp4'; // 其余 brand 一律按 mp4 容器
    }
    return byMagic;
  }

  /// mime → 播放器友好的扩展名。extensionFromMime 个别结果 AVFoundation
  /// 不认(audio/mpeg → mpga),覆盖为通行形态。
  @visibleForTesting
  static String extensionForMimeType(String mime) {
    switch (mime) {
      case 'audio/mpeg':
        return 'mp3';
      case 'audio/mp4':
        return 'm4a';
    }
    return extensionFromMime(mime) ?? 'bin';
  }

  /// Range 抓头部字节(流式 + 提前断流,防服务端无视 Range 整文件回灌);
  /// 头响应报告总大小超过 [_maxLocalizeBytes] 时返回 null 放弃。
  Future<Uint8List?> _fetchHead(String url) async {
    final cancel = CancelToken();
    final resp = await _dio.get<ResponseBody>(
      url,
      cancelToken: cancel,
      options: Options(
        responseType: ResponseType.stream,
        headers: {'Range': 'bytes=0-${_sniffBytes - 1}'},
        followRedirects: true,
        maxRedirects: 3,
        validateStatus: (s) => s == 200 || s == 206,
      ),
    );
    final stream = resp.data?.stream;
    if (stream == null) return null;

    final total = _totalSizeOf(resp);
    if (total != null && total > _maxLocalizeBytes) {
      _safeCancel(cancel);
      return null;
    }

    final buf = BytesBuilder(copy: false);
    try {
      await for (final chunk in stream) {
        buf.add(chunk);
        if (buf.length >= _sniffBytes) break;
      }
    } finally {
      _safeCancel(cancel); // 已拿够字节,断开连接
    }
    return buf.isEmpty ? null : buf.takeBytes();
  }

  static void _safeCancel(CancelToken token) {
    try {
      token.cancel('sniff-done');
    } catch (_) {}
  }

  /// 从 Content-Range(206)或 Content-Length(200)取文件总大小。
  static int? _totalSizeOf(Response<ResponseBody> resp) {
    final range = resp.headers.value('content-range'); // bytes 0-511/893051
    final slash = range?.lastIndexOf('/') ?? -1;
    if (range != null && slash != -1) {
      return int.tryParse(range.substring(slash + 1));
    }
    if (resp.statusCode == 200) {
      return int.tryParse(resp.headers.value('content-length') ?? '');
    }
    return null;
  }

  /// 整文件下载到本地缓存,以正确扩展名命名(sha1(url) 确定性文件名,
  /// 重启后磁盘副本直接复用)。
  Future<File> _localize(String url, String ext) async {
    final dir = await _cacheDir();
    final name = sha1.convert(utf8.encode(url)).toString();
    final file = File('${dir.path}/$name.$ext');
    if (await file.exists() && await file.length() > 0) return file;
    final tmp = '${file.path}.part';
    await _dio.download(
      url,
      tmp,
      options: Options(followRedirects: true, maxRedirects: 3),
    );
    await File(tmp).rename(file.path);
    return file;
  }

  /// webm/opus 重封装大小上限:语音消息都是 KB 级,超限的多半是
  /// webm 视频(反正也接管不了),不值得整读进内存。
  static const _maxRemuxBytes = 64 << 20;

  /// 下载 webm 并把 Opus 音轨无损重封装为 CAF(webm_opus_to_caf.dart)。
  /// 解析/封装在 isolate 里跑,防大文件卡主线程;不可接管返回 null。
  Future<File?> _remuxWebmOpusToCaf(String url) async {
    final dir = await _cacheDir();
    final name = sha1.convert(utf8.encode(url)).toString();
    final target = File('${dir.path}/$name.caf');
    if (await target.exists() && await target.length() > 0) return target;
    final part = File('${target.path}.part');
    await _dio.download(
      url,
      part.path,
      options: Options(followRedirects: true, maxRedirects: 3),
    );
    try {
      if (await part.length() > _maxRemuxBytes) return null;
      final caf = await compute(webmOpusToCaf, await part.readAsBytes());
      if (caf == null) return null;
      await target.writeAsBytes(caf);
      return target;
    } finally {
      if (await part.exists()) await part.delete();
    }
  }

  Future<Directory> _cacheDir() => _dirFuture ??= () async {
        final base = await getTemporaryDirectory();
        final dir = Directory('${base.path}/$_dirName');
        await dir.create(recursive: true);
        _sweepStale(dir);
        return dir;
      }();

  /// 惰性清理:30 天前的本地副本(含中断残留的 .part)删除,
  /// 防磁盘无界增长;目录本身在 Temporary 下,系统清缓存也能回收。
  void _sweepStale(Directory dir) {
    if (_swept) return;
    _swept = true;
    unawaited(Future(() async {
      try {
        final cutoff = DateTime.now().subtract(const Duration(days: 30));
        await for (final e in dir.list()) {
          if (e is! File) continue;
          if ((await e.stat()).modified.isBefore(cutoff)) {
            await e.delete();
          }
        }
      } catch (_) {
        // 清理失败无碍,下次会话再试
      }
    }));
  }
}
