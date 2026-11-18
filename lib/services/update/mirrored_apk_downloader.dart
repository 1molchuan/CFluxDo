import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'github_mirror_policy.dart';

/// 下载过程中的事件（给界面显示线路和进度）
sealed class MirrorDownloadEvent {
  const MirrorDownloadEvent();
}

/// 测速进度
class MirrorProbeProgress extends MirrorDownloadEvent {
  const MirrorProbeProgress(this.done, this.total);
  final int done;
  final int total;
}

/// 开始用某条线路下载；[previous] 不为空表示是从那条换过来的
class MirrorRouteSelected extends MirrorDownloadEvent {
  const MirrorRouteSelected(this.route, {this.previous, this.reason});
  final DownloadRoute route;
  final DownloadRoute? previous;
  final MirrorSwitchReason? reason;
}

/// 已下载字节数（[total] 不知道时为 0）
class MirrorDownloadProgress extends MirrorDownloadEvent {
  const MirrorDownloadProgress(this.received, this.total);
  final int received;
  final int total;
}

/// 下完正在核对 SHA-256
class MirrorVerifying extends MirrorDownloadEvent {
  const MirrorVerifying();
}

/// 换线原因
enum MirrorSwitchReason {
  /// 连不上 / 出错
  failed,

  /// 一段时间一个字节都没来
  stalled,

  /// 来得太慢
  slow,

  /// 给的不是 APK（镜像的报错页之类）
  notApk,

  /// 断了、没下完
  incomplete,
}

/// 一条线路的测速结果
class MirrorProbeResult {
  const MirrorProbeResult(this.route, {required this.ok, this.elapsed});
  final DownloadRoute route;
  final bool ok;

  /// 拉完测速那一小段用了多久（失败为 null）
  final Duration? elapsed;
}

class MirrorDownloadException implements Exception {
  const MirrorDownloadException(this.kind, [this.detail]);

  final MirrorDownloadFailure kind;
  final String? detail;

  @override
  String toString() =>
      'MirrorDownloadException($kind${detail == null ? '' : ': $detail'})';
}

enum MirrorDownloadFailure {
  /// 所有线路都没下完
  allRoutesFailed,

  /// 下完了但 SHA-256 对不上（换掉出过力的公共镜像重下一次后仍然不对）
  checksumMismatch,

  cancelled,
}

/// 一条线路本轮放弃（换下一条）
class _Abandon implements Exception {
  const _Abandon(this.reason, [this.detail]);
  final MirrorSwitchReason reason;
  final String? detail;
}

/// 多线路下载 APK：先对所有线路测速（真的拉一小段、确认是 APK），按快慢
/// 排序；下载时卡住或太慢自动换下一条，从断点接着下；下完按 SHA-256 核对。
///
/// 和 SOMCP（bilieebiliee1-design/SOMCP，只借思路）的区别：测速拉真实数据
/// 而不是 HEAD（HEAD 快不代表下载快，也认不出镜像回的报错页），下载中途
/// 卡住 [stallTimeout] 就换线，不用干等读超时。
class MirroredApkDownloader {
  MirroredApkDownloader({
    Dio? dio,
    this.probeBytes = 128 * 1024,
    this.probeTimeout = const Duration(seconds: 8),
    this.stallTimeout = const Duration(seconds: 15),
    this.slowWindow = const Duration(seconds: 20),
    this.slowBytesPerSecond = 48 * 1024,
    this.userAgent = 'CFluxDo-Updater',
  }) : _dio =
           dio ??
           Dio(
             BaseOptions(
               connectTimeout: const Duration(seconds: 10),
               followRedirects: true,
             ),
           );

  final Dio _dio;

  /// 测速每条线路拉多少字节
  final int probeBytes;
  final Duration probeTimeout;

  /// 多久一个字节都没来就换线
  final Duration stallTimeout;

  /// 在一条线路上下了这么久之后，平均速度低于 [slowBytesPerSecond] 且还有
  /// 别的线路可换就换
  final Duration slowWindow;
  final int slowBytesPerSecond;
  final String userAgent;

  static const _apkMagic = [0x50, 0x4B, 0x03, 0x04];

  /// 并发测速。顺序与 [routes] 一致。
  Future<List<MirrorProbeResult>> probe(
    List<DownloadRoute> routes, {
    CancelToken? cancel,
    void Function(int done, int total)? onProgress,
  }) async {
    var done = 0;
    return Future.wait([
      for (final route in routes)
        _probeOne(route, cancel).then((result) {
          done++;
          onProgress?.call(done, routes.length);
          return result;
        }),
    ]);
  }

  Future<MirrorProbeResult> _probeOne(
    DownloadRoute route,
    CancelToken? outer,
  ) async {
    final token = CancelToken();
    void onOuterCancel() => token.cancel();
    outer?.whenCancel.then((_) => onOuterCancel());
    final watch = Stopwatch()..start();
    try {
      final received = await _readHead(route.url, token).timeout(
        probeTimeout,
        onTimeout: () {
          token.cancel('probe timeout');
          return null;
        },
      );
      if (received == null) return MirrorProbeResult(route, ok: false);
      return MirrorProbeResult(route, ok: true, elapsed: watch.elapsed);
    } catch (_) {
      return MirrorProbeResult(route, ok: false);
    } finally {
      if (!token.isCancelled) token.cancel('probe done');
    }
  }

  /// 拉前 [probeBytes] 字节，是 APK 就返回拿到的字节数，否则 null
  Future<int?> _readHead(String url, CancelToken token) async {
    final response = await _dio.get<ResponseBody>(
      url,
      cancelToken: token,
      options: Options(
        responseType: ResponseType.stream,
        headers: {
          'Range': 'bytes=0-${probeBytes - 1}',
          'User-Agent': userAgent,
        },
        validateStatus: (_) => true,
      ),
    );
    final status = response.statusCode ?? 0;
    final body = response.data;
    if (body == null || (status != 200 && status != 206)) return null;
    final head = <int>[];
    var received = 0;
    await for (final chunk in body.stream) {
      if (head.length < 4) {
        head.addAll(chunk.take(4 - head.length));
        if (head.length == 4 && !listEquals(head, _apkMagic)) return null;
      }
      received += chunk.length;
      if (received >= probeBytes) break;
    }
    if (head.length < 4) return null;
    return received;
  }

  /// 测速结果排序：通的按快慢；不通的公共镜像不要了，不通的官方直连和
  /// 用户自己填的放最后兜底（测速超时不等于下不动）
  static List<DownloadRoute> rank(List<MirrorProbeResult> results) {
    final ok = results.where((r) => r.ok).toList()
      ..sort((a, b) => a.elapsed!.compareTo(b.elapsed!));
    return [
      for (final r in ok) r.route,
      for (final r in results)
        if (!r.ok && (r.route.official || r.route.userConfigured)) r.route,
    ];
  }

  /// 按 [routes] 的顺序下载到 [target]。
  ///
  /// 换线时从已下到的位置用 Range 接着下（服务端不认 Range 就从头）；全部
  /// 下完核对 [expectedSha256]，对不上就把这次出过力的公共镜像剔掉、从头
  /// 再下一遍，还不对才报错。
  Future<File> download({
    required List<DownloadRoute> routes,
    required File target,
    int? expectedSize,
    String? expectedSha256,
    CancelToken? cancel,
    void Function(MirrorDownloadEvent event)? onEvent,
  }) async {
    final part = File('${target.path}.part');
    await part.parent.create(recursive: true);
    if (await part.exists()) await part.delete();

    var candidates = routes;
    for (var round = 0; round < 2; round++) {
      final contributors = <DownloadRoute>{};
      await _downloadOnce(
        routes: candidates,
        part: part,
        expectedSize: expectedSize,
        cancel: cancel,
        onEvent: onEvent,
        contributors: contributors,
      );
      if (expectedSha256 == null) break;
      onEvent?.call(const MirrorVerifying());
      final actual = await fileSha256(part);
      if (actual == expectedSha256.toLowerCase()) break;
      await part.delete();
      final remaining = [
        for (final route in candidates)
          if (route.official ||
              route.userConfigured ||
              !contributors.contains(route))
            route,
      ];
      if (round == 1 || remaining.isEmpty) {
        throw MirrorDownloadException(
          MirrorDownloadFailure.checksumMismatch,
          contributors.map((r) => r.label).join(','),
        );
      }
      candidates = remaining;
    }
    if (await target.exists()) await target.delete();
    return part.rename(target.path);
  }

  Future<void> _downloadOnce({
    required List<DownloadRoute> routes,
    required File part,
    required int? expectedSize,
    required CancelToken? cancel,
    required void Function(MirrorDownloadEvent event)? onEvent,
    required Set<DownloadRoute> contributors,
  }) async {
    DownloadRoute? previous;
    MirrorSwitchReason? reason;
    String? lastDetail;
    for (var i = 0; i < routes.length; i++) {
      if (cancel?.isCancelled ?? false) {
        throw const MirrorDownloadException(MirrorDownloadFailure.cancelled);
      }
      final route = routes[i];
      onEvent?.call(
        MirrorRouteSelected(route, previous: previous, reason: reason),
      );
      try {
        await _fetchInto(
          route: route,
          part: part,
          expectedSize: expectedSize,
          cancel: cancel,
          onEvent: onEvent,
          hasAlternatives: i < routes.length - 1,
          onBytes: () => contributors.add(route),
        );
        return;
      } on _Abandon catch (e) {
        if (cancel?.isCancelled ?? false) {
          throw const MirrorDownloadException(MirrorDownloadFailure.cancelled);
        }
        debugPrint(
          '[MirroredApkDownloader] ${route.label} 放弃: ${e.reason} ${e.detail ?? ''}',
        );
        previous = route;
        reason = e.reason;
        lastDetail =
            '${route.label}: ${e.reason.name}${e.detail == null ? '' : ' ${e.detail}'}';
      }
    }
    throw MirrorDownloadException(
      MirrorDownloadFailure.allRoutesFailed,
      lastDetail,
    );
  }

  Future<void> _fetchInto({
    required DownloadRoute route,
    required File part,
    required int? expectedSize,
    required CancelToken? cancel,
    required void Function(MirrorDownloadEvent event)? onEvent,
    required bool hasAlternatives,
    required void Function() onBytes,
  }) async {
    var offset = await part.exists() ? await part.length() : 0;
    if (expectedSize != null && offset >= expectedSize) {
      if (offset == expectedSize) return;
      await part.writeAsBytes(const []);
      offset = 0;
    }

    final token = CancelToken();
    StreamSubscription<void>? outerCancel;
    if (cancel != null) {
      outerCancel = cancel.whenCancel.asStream().listen((_) {
        if (!token.isCancelled) token.cancel('user cancelled');
      });
    }

    Response<ResponseBody> response;
    try {
      response = await _dio
          .get<ResponseBody>(
            route.url,
            cancelToken: token,
            options: Options(
              responseType: ResponseType.stream,
              headers: {
                if (offset > 0) 'Range': 'bytes=$offset-',
                'User-Agent': userAgent,
              },
              validateStatus: (_) => true,
            ),
          )
          .timeout(
            stallTimeout,
            onTimeout: () {
              token.cancel('connect stalled');
              throw const _Abandon(MirrorSwitchReason.stalled, 'no response');
            },
          );
    } on _Abandon {
      await outerCancel?.cancel();
      rethrow;
    } catch (e) {
      await outerCancel?.cancel();
      throw _Abandon(MirrorSwitchReason.failed, _short(e));
    }

    final status = response.statusCode ?? 0;
    final body = response.data;
    if (body == null || (status != 200 && status != 206)) {
      token.cancel('bad status');
      await outerCancel?.cancel();
      throw _Abandon(MirrorSwitchReason.failed, 'HTTP $status');
    }

    var writeOffset = offset;
    if (status == 206) {
      final start = _contentRangeStart(response.headers.value('content-range'));
      if (start != offset) {
        // 给的不是要的那一段：从头来
        writeOffset = 0;
        if (start != 0) {
          token.cancel('bad range');
          await outerCancel?.cancel();
          throw _Abandon(MirrorSwitchReason.failed, 'range $start != $offset');
        }
      }
    } else {
      // 200：服务端不认 Range，整个文件从头给
      writeOffset = 0;
    }
    final total = expectedSize ?? _totalSize(response, writeOffset) ?? 0;

    // 从头写时先确认开头是 APK 再动文件：镜像回的报错页不能把已下的部分清掉
    IOSink? sink = writeOffset == 0
        ? null
        : part.openWrite(mode: FileMode.append);
    final pending = <Uint8List>[];
    var received = writeOffset;
    final head = <int>[];
    final started = DateTime.now();
    var lastByteAt = started;
    var bytesThisRoute = 0;
    final done = Completer<void>();
    late StreamSubscription<Uint8List> sub;

    void abandon(_Abandon reason) {
      if (done.isCompleted) return;
      token.cancel(reason.reason.name);
      sub.cancel();
      done.completeError(reason);
    }

    final watchdog = Timer.periodic(const Duration(milliseconds: 500), (_) {
      final now = DateTime.now();
      if (now.difference(lastByteAt) >= stallTimeout) {
        abandon(const _Abandon(MirrorSwitchReason.stalled));
        return;
      }
      final elapsed = now.difference(started);
      if (hasAlternatives && elapsed >= slowWindow) {
        final rate = bytesThisRoute * 1000 / elapsed.inMilliseconds;
        if (rate < slowBytesPerSecond) {
          abandon(_Abandon(MirrorSwitchReason.slow, '${rate.round()} B/s'));
        }
      }
    });

    sub = body.stream.listen(
      (chunk) {
        if (done.isCompleted) return;
        lastByteAt = DateTime.now();
        if (sink == null) {
          head.addAll(chunk.take(4 - head.length));
          if (head.length < 4) {
            pending.add(chunk);
            received += chunk.length;
            bytesThisRoute += chunk.length;
            return;
          }
          if (!listEquals(head, _apkMagic)) {
            abandon(const _Abandon(MirrorSwitchReason.notApk));
            return;
          }
          sink = part.openWrite(mode: FileMode.write);
          for (final early in pending) {
            sink!.add(early);
          }
          pending.clear();
        }
        sink!.add(chunk);
        received += chunk.length;
        bytesThisRoute += chunk.length;
        if (chunk.isNotEmpty) onBytes();
        onEvent?.call(MirrorDownloadProgress(received, total));
      },
      onError: (Object e) {
        if (!done.isCompleted) {
          done.completeError(
            cancel?.isCancelled ?? false
                ? const _Abandon(MirrorSwitchReason.failed, 'cancelled')
                : _Abandon(MirrorSwitchReason.failed, _short(e)),
          );
        }
      },
      onDone: () {
        if (!done.isCompleted) done.complete();
      },
      cancelOnError: true,
    );

    try {
      await done.future;
    } finally {
      watchdog.cancel();
      await sink?.flush();
      await sink?.close();
      await outerCancel?.cancel();
    }
    if (sink == null) {
      // 一个字节没写（连开头都没凑够 4 字节就结束了）
      throw const _Abandon(MirrorSwitchReason.incomplete, 'empty body');
    }

    if (expectedSize != null && received != expectedSize) {
      if (received > expectedSize) await part.writeAsBytes(const []);
      throw _Abandon(MirrorSwitchReason.incomplete, '$received/$expectedSize');
    }
  }

  static int? _contentRangeStart(String? header) {
    final match = RegExp(r'bytes\s+(\d+)-').firstMatch(header ?? '');
    return match == null ? null : int.tryParse(match.group(1)!);
  }

  static int? _totalSize(Response<ResponseBody> response, int offset) {
    final range = RegExp(r'/(\d+)$')
        .firstMatch(response.headers.value('content-range') ?? '');
    if (range != null) return int.tryParse(range.group(1)!);
    final length = int.tryParse(
      response.headers.value(Headers.contentLengthHeader) ?? '',
    );
    return length == null ? null : length + offset;
  }

  static String _short(Object e) {
    final text = e is DioException
        ? '${e.type.name} ${e.error ?? ''}'
        : e.toString();
    final line = text.split('\n').first;
    return line.length > 160 ? line.substring(0, 160) : line;
  }

  /// 文件的 SHA-256（小写十六进制），在后台 isolate 里算，不卡界面
  static Future<String> fileSha256(File file) {
    final path = file.path;
    return Isolate.run(() async {
      final digest = await sha256.bind(File(path).openRead()).first;
      return digest.toString();
    });
  }
}
