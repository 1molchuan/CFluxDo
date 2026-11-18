import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:ota_update/ota_update.dart';
import 'package:path_provider/path_provider.dart';

import '../l10n/s.dart';
import 'log/log_writer.dart';
import 'update/github_mirror_policy.dart';
import 'update/mirrored_apk_downloader.dart';
import 'update_service.dart';

/// APK 下载状态
enum ApkDownloadStatus {
  idle,
  downloading,
  verifying,
  installing,
  completed,
  error,
}

/// APK 下载进度
class ApkDownloadProgress {
  final ApkDownloadStatus status;
  final int progress; // 0-100
  final String? error;

  /// 补充说明：测速进度、当前线路、换线（显示在状态文字下面）
  final String? detail;

  ApkDownloadProgress({
    required this.status,
    this.progress = 0,
    this.error,
    this.detail,
  });
}

/// APK 下载安装服务
///
/// 下载自己做（[MirroredApkDownloader]：GitHub 直连 + 公共镜像测速选线、
/// 卡住换线、断点续传、按 GitHub 接口给的 SHA-256 核对），下完在本机
/// 127.0.0.1 临时开一个只给这一个文件的地址交给 ota_update，安装仍走它
/// 原来那套（权限、FileProvider、安装结果回报都不变）。
///
/// 以前直接把 GitHub（或用户填的一个反代）链接交给 ota_update：国内很多
/// 网络直连 GitHub 下载卡在 0%，最后失败，只能去网页手动下（2026-11 佬友
/// 反馈）。
class ApkDownloadService {
  ApkDownloadService({Dio? dio, MirroredApkDownloader? downloader})
    : _dio = dio ?? Dio(),
      _downloader = downloader ?? MirroredApkDownloader();

  final Dio _dio;
  final MirroredApkDownloader _downloader;
  CancelToken? _cancel;
  bool _cancelled = false;

  /// 下载并安装 APK，返回进度 Stream
  Stream<ApkDownloadProgress> downloadAndInstall(ApkAsset asset) {
    _cancelled = false;
    _cancel?.cancel('restart');
    final cancel = _cancel = CancelToken();
    final controller = StreamController<ApkDownloadProgress>();
    controller.onListen = () {
      _run(asset, cancel, controller).whenComplete(controller.close);
    };
    controller.onCancel = () {
      if (!cancel.isCancelled) cancel.cancel('listener cancelled');
    };
    return controller.stream;
  }

  Future<void> _run(
    ApkAsset asset,
    CancelToken cancel,
    StreamController<ApkDownloadProgress> out,
  ) async {
    void emit(ApkDownloadProgress p) {
      if (!out.isClosed && !_cancelled) out.add(p);
    }

    File? file;
    try {
      // 阶段 1：可信的校验值。接口给的 digest 优先；没有（旧缓存）再去
      // GitHub 官方地址取 .sha256，绝不经公共镜像——镜像能同时改 APK 和
      // 校验文件。拿不到就不用公共镜像，只走官方直连和用户自己填的反代
      emit(ApkDownloadProgress(status: ApkDownloadStatus.verifying));
      final userProxy = await UpdateService.getGithubProxy();
      var expectedSha256 = asset.sha256;
      if (expectedSha256 == null && asset.sha256Url != null) {
        expectedSha256 = await _fetchSha256Checksum(asset.sha256Url!, cancel);
        if (expectedSha256 == null && userProxy.isNotEmpty) {
          expectedSha256 = await _fetchSha256Checksum(
            UpdateService.applyGithubProxy(asset.sha256Url!, userProxy),
            cancel,
          );
        }
      }
      if (_cancelled) return;

      // 阶段 2：测速选线
      final routes = GithubMirrorPolicy.routes(
        asset.downloadUrl,
        userProxy: userProxy,
        allowPublicMirrors: expectedSha256 != null,
      );
      var ranked = routes;
      if (routes.length > 1) {
        emit(
          ApkDownloadProgress(
            status: ApkDownloadStatus.verifying,
            detail: S.current.download_probingRoutes(0, routes.length),
          ),
        );
        final results = await _downloader.probe(
          routes,
          cancel: cancel,
          onProgress: (done, total) => emit(
            ApkDownloadProgress(
              status: ApkDownloadStatus.verifying,
              detail: S.current.download_probingRoutes(done, total),
            ),
          ),
        );
        if (_cancelled) return;
        ranked = MirroredApkDownloader.rank(results);
        _log('apk_route_probe', {
          'routes': [
            for (final r in results)
              {
                'route': r.route.label,
                'ok': r.ok,
                if (r.elapsed != null) 'ms': r.elapsed!.inMilliseconds,
              },
          ],
          'hasChecksum': expectedSha256 != null,
        });
        if (ranked.isEmpty) ranked = routes;
      }

      // 阶段 3：下载（卡住 / 太慢自动换线）
      final dir = Directory(
        '${(await getTemporaryDirectory()).path}/apk_update',
      );
      final target = File('${dir.path}/${asset.name}');
      var route = ranked.first.label;
      var percent = -1;
      emit(
        ApkDownloadProgress(
          status: ApkDownloadStatus.downloading,
          progress: 0,
          detail: S.current.download_route(route),
        ),
      );
      file = await _downloader.download(
        routes: ranked,
        target: target,
        expectedSize: asset.size > 0 ? asset.size : null,
        expectedSha256: expectedSha256,
        cancel: cancel,
        onEvent: (event) {
          switch (event) {
            case MirrorRouteSelected(
              route: final next,
              :final previous,
              :final reason,
            ):
              final current = percent < 0 ? 0 : percent;
              _routeLabel = next.label;
              emit(
                ApkDownloadProgress(
                  status: ApkDownloadStatus.downloading,
                  progress: current,
                  detail: previous == null
                      ? S.current.download_route(next.label)
                      : S.current.download_routeSwitched(
                          previous.label,
                          next.label,
                        ),
                ),
              );
              if (previous != null) {
                _log('apk_route_switched', {
                  'from': previous.label,
                  'to': next.label,
                  'reason': reason?.name,
                  'progress': current,
                });
              }
            case MirrorDownloadProgress(:final received, :final total):
              if (total <= 0) return;
              final p = min(99, received * 100 ~/ total);
              if (p == percent) return;
              percent = p;
              emit(
                ApkDownloadProgress(
                  status: ApkDownloadStatus.downloading,
                  progress: p,
                  detail: S.current.download_route(_routeLabel ?? route),
                ),
              );
            case MirrorVerifying():
              emit(ApkDownloadProgress(status: ApkDownloadStatus.verifying));
            case MirrorProbeProgress():
              break;
          }
        },
      );
      route = _routeLabel ?? route;
      _log('apk_download_done', {
        'route': route,
        'verified': expectedSha256 != null,
      });
      if (_cancelled) return;

      // 阶段 4：交给 ota_update 安装
      await for (final p in _install(file, asset, expectedSha256)) {
        emit(p);
      }
    } on MirrorDownloadException catch (e) {
      if (e.kind == MirrorDownloadFailure.cancelled || _cancelled) return;
      _log('apk_download_failed', {'kind': e.kind.name, 'detail': e.detail});
      emit(
        ApkDownloadProgress(
          status: ApkDownloadStatus.error,
          error: e.kind == MirrorDownloadFailure.checksumMismatch
              ? S.current.download_checksumFailed
              : S.current.download_allRoutesFailed,
        ),
      );
    } catch (e) {
      if (_cancelled) return;
      _log('apk_download_failed', {'kind': 'exception', 'detail': '$e'});
      emit(
        ApkDownloadProgress(
          status: ApkDownloadStatus.error,
          error: S.current.download_failed('$e'),
        ),
      );
    } finally {
      _routeLabel = null;
      if (file != null) {
        try {
          if (await file.exists()) await file.delete();
        } catch (_) {}
      }
    }
  }

  String? _routeLabel;

  /// 下好的文件经本机临时地址交给 ota_update 安装（它自己再核对一遍 SHA-256）。
  /// 它拷完（报 INSTALLING）就关掉临时地址、删掉这边的文件：走系统安装界面
  /// 时它的事件流可能一直不结束，不能等流结束再收拾
  Stream<ApkDownloadProgress> _install(
    File file,
    ApkAsset asset,
    String? sha256,
  ) async* {
    final server = await ApkLoopbackServer.start(file);
    var handedOff = false;
    Future<void> handOff() async {
      if (handedOff) return;
      handedOff = true;
      await server.close();
      try {
        if (await file.exists()) await file.delete();
      } catch (_) {}
    }

    try {
      yield ApkDownloadProgress(
        status: ApkDownloadStatus.installing,
        progress: 100,
      );
      final events = OtaUpdate().execute(
        server.url,
        destinationFilename: asset.name,
        sha256checksum: sha256,
      );
      await for (final event in events) {
        if (_cancelled) return;
        switch (event.status) {
          case OtaStatus.DOWNLOADING:
            // 从本机拷过去，很快；界面停在「正在安装」
            break;
          case OtaStatus.INSTALLING:
            await handOff();
            yield ApkDownloadProgress(
              status: ApkDownloadStatus.installing,
              progress: 100,
            );
          case OtaStatus.ALREADY_RUNNING_ERROR:
            yield ApkDownloadProgress(
              status: ApkDownloadStatus.error,
              error: S.current.download_alreadyInProgress,
            );
          case OtaStatus.PERMISSION_NOT_GRANTED_ERROR:
            yield ApkDownloadProgress(
              status: ApkDownloadStatus.error,
              error: S.current.download_noInstallPermission,
            );
          case OtaStatus.INTERNAL_ERROR:
            yield ApkDownloadProgress(
              status: ApkDownloadStatus.error,
              error: event.value ?? S.current.download_internalError,
            );
          case OtaStatus.DOWNLOAD_ERROR:
            yield ApkDownloadProgress(
              status: ApkDownloadStatus.error,
              error: S.current.download_failedWithError(
                event.value ?? S.current.error_unknown,
              ),
            );
          case OtaStatus.CHECKSUM_ERROR:
            yield ApkDownloadProgress(
              status: ApkDownloadStatus.error,
              error: S.current.download_checksumFailed,
            );
          case OtaStatus.INSTALLATION_DONE:
            yield ApkDownloadProgress(
              status: ApkDownloadStatus.completed,
              progress: 100,
            );
          case OtaStatus.INSTALLATION_ERROR:
            yield ApkDownloadProgress(
              status: ApkDownloadStatus.error,
              error: S.current.download_installFailed(
                event.value ?? S.current.error_unknown,
              ),
            );
          case OtaStatus.CANCELED:
            return;
        }
      }
    } finally {
      await handOff();
    }
  }

  /// 获取 SHA256 校验和（"hash  filename" 或仅 "hash"）
  Future<String?> _fetchSha256Checksum(String url, CancelToken cancel) async {
    try {
      final response = await _dio.get<String>(
        url,
        cancelToken: cancel,
        options: Options(
          responseType: ResponseType.plain,
          sendTimeout: const Duration(seconds: 8),
          receiveTimeout: const Duration(seconds: 8),
        ),
      );
      final content = response.data?.trim() ?? '';
      final hash = content.split(RegExp(r'\s+')).first.toLowerCase();
      if (RegExp(r'^[0-9a-f]{64}$').hasMatch(hash)) return hash;
    } catch (e) {
      // 取不到就当没有：只走官方直连和用户自己填的反代
    }
    return null;
  }

  void _log(String event, Map<String, Object?> fields) {
    LogWriter.instance.write({
      'timestamp': DateTime.now().toIso8601String(),
      'level': event.endsWith('failed') ? 'warning' : 'info',
      'type': 'update',
      'event': event,
      'message': '应用内更新: $event',
      ...fields,
    });
  }

  /// 取消下载
  void cancelDownload() {
    _cancelled = true;
    _cancel?.cancel('user cancelled');
  }
}

/// 在 127.0.0.1 上临时提供一个文件，路径带随机串，只给 ota_update 取一次。
@visibleForTesting
class ApkLoopbackServer {
  ApkLoopbackServer._(this._server, this.url);

  final HttpServer _server;
  final String url;

  static Future<ApkLoopbackServer> start(File file) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final random = Random.secure();
    final token = List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final name = Uri.encodeComponent(file.uri.pathSegments.last);
    final path = '/$token/$name';
    server.listen((request) async {
      final response = request.response;
      try {
        if (request.uri.path != path ||
            (request.method != 'GET' && request.method != 'HEAD')) {
          response.statusCode = HttpStatus.notFound;
          await response.close();
          return;
        }
        response.headers
          ..contentType = ContentType(
            'application',
            'vnd.android.package-archive',
          )
          ..contentLength = await file.length();
        if (request.method == 'HEAD') {
          await response.close();
          return;
        }
        await response.addStream(file.openRead());
        await response.close();
      } catch (_) {
        try {
          await response.close();
        } catch (_) {}
      }
    });
    return ApkLoopbackServer._(
      server,
      'http://${InternetAddress.loopbackIPv4.address}:${server.port}$path',
    );
  }

  Future<void> close() => _server.close(force: true);
}
