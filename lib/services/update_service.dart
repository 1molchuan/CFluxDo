import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;

import 'package:device_info_plus/device_info_plus.dart';
import 'package:dio/dio.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/s.dart';

/// APK 资源信息
class ApkAsset {
  final String downloadUrl;
  final String? sha256Url;
  final String architecture;
  final int size;
  final String name;

  ApkAsset({
    required this.downloadUrl,
    this.sha256Url,
    required this.architecture,
    required this.size,
    required this.name,
  });

  Map<String, dynamic> toJson() => {
        'downloadUrl': downloadUrl,
        'sha256Url': sha256Url,
        'architecture': architecture,
        'size': size,
        'name': name,
      };

  factory ApkAsset.fromJson(Map<String, dynamic> json) => ApkAsset(
        downloadUrl: json['downloadUrl'] as String,
        sha256Url: json['sha256Url'] as String?,
        architecture: json['architecture'] as String,
        size: json['size'] as int,
        name: json['name'] as String,
      );
}

/// 更新信息模型
class UpdateInfo {
  final String currentVersion;
  final String remoteVersion;
  final String releaseUrl;
  final String releaseNotes;
  final bool hasUpdate;
  final List<ApkAsset> apkAssets;

  UpdateInfo({
    required this.currentVersion,
    required this.remoteVersion,
    required this.releaseUrl,
    required this.releaseNotes,
    required this.hasUpdate,
    this.apkAssets = const [],
  });

  Map<String, dynamic> toJson() => {
        'currentVersion': currentVersion,
        'remoteVersion': remoteVersion,
        'releaseUrl': releaseUrl,
        'releaseNotes': releaseNotes,
        'hasUpdate': hasUpdate,
        'apkAssets': apkAssets.map((e) => e.toJson()).toList(),
      };

  factory UpdateInfo.fromJson(Map<String, dynamic> json) => UpdateInfo(
        currentVersion: json['currentVersion'] as String,
        remoteVersion: json['remoteVersion'] as String,
        releaseUrl: json['releaseUrl'] as String,
        releaseNotes: json['releaseNotes'] as String,
        hasUpdate: json['hasUpdate'] as bool,
        apkAssets: (json['apkAssets'] as List<dynamic>?)
                ?.map((e) => ApkAsset.fromJson(e as Map<String, dynamic>))
                .toList() ??
            [],
      );
}

/// 应用更新检查服务
class UpdateService {
  // cfluxdo 从 fork 的 Release 检查更新(包名与签名都和官方版不同,不能装官方包)
  static const String _repository = '1molchuan/CFluxDo';
  static const String _apiUrl =
      'https://api.github.com/repos/$_repository/releases/latest';
  static const String _autoCheckUpdateKey = 'auto_check_update';
  static const String _githubProxyKey = 'github_proxy_url';
  static const String _cacheKey = 'update_cache';
  static const String _cacheTimeKey = 'update_cache_time';
  static const String _etagKey = 'update_etag';

  // 缓存有效期（1 小时）
  static const Duration _cacheValidDuration = Duration(hours: 1);

  final Dio _dio;
  final SharedPreferences? _prefs;

  UpdateService({Dio? dio, SharedPreferences? prefs})
      : _dio = dio ?? Dio(),
        _prefs = prefs;

  /// 获取自动检查更新设置
  bool getAutoCheckUpdate() {
    return _prefs?.getBool(_autoCheckUpdateKey) ?? true;
  }

  /// 获取自定义 GitHub 反代前缀（空字符串表示未配置，直连）
  static Future<String> getGithubProxy() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_githubProxyKey) ?? '';
  }

  /// 保存自定义 GitHub 反代前缀，传空字符串表示清除
  static Future<void> setGithubProxy(String url) async {
    final prefs = await SharedPreferences.getInstance();
    final normalized = normalizeGithubProxy(url);
    if (normalized.isEmpty) {
      await prefs.remove(_githubProxyKey);
    } else {
      await prefs.setString(_githubProxyKey, normalized);
    }
  }

  /// 规范化反代前缀：去空白、补末尾斜杠
  static String normalizeGithubProxy(String raw) {
    var url = raw.trim();
    if (url.isEmpty) return '';
    if (!url.endsWith('/')) url = '$url/';
    return url;
  }

  /// 校验反代前缀是否为合法的 http(s) 地址
  static bool isValidGithubProxy(String raw) {
    final uri = Uri.tryParse(normalizeGithubProxy(raw));
    return uri != null &&
        (uri.scheme == 'http' || uri.scheme == 'https') &&
        uri.host.isNotEmpty;
  }

  /// 将反代前缀拼接到原始下载链接前（gh-proxy 系通用格式：前缀 + 完整原始 URL）
  static String applyGithubProxy(String url, String proxy) {
    final prefix = normalizeGithubProxy(proxy);
    if (prefix.isEmpty) return url;
    // 已经带前缀的链接不重复拼接
    if (url.startsWith(prefix)) return url;
    return '$prefix$url';
  }

  /// 设置自动检查更新
  Future<void> setAutoCheckUpdate(bool value) async {
    await _prefs?.setBool(_autoCheckUpdateKey, value);
  }

  /// 获取当前应用版本号
  Future<String> getCurrentVersion() async {
    final packageInfo = await PackageInfo.fromPlatform();
    return packageInfo.version;
  }

  /// 发行包提供的 ABI，按优先级排列(见 README 下载说明)：64 位机优先装 arm64 包
  static const List<String> releaseAbis = ['arm64-v8a', 'armeabi-v7a'];

  /// 当前设备应装哪种发行包：按设备自己声明的 ABI 顺序（64 位机把 arm64-v8a
  /// 排在前面），取第一个我们有包的；都没有返回 null
  Future<String?> preferredReleaseAbi() async {
    if (!Platform.isAndroid) return null;

    try {
      final androidInfo = await DeviceInfoPlugin().androidInfo;
      return pickReleaseAbi(androidInfo.supportedAbis);
    } catch (e) {
      return null;
    }
  }

  /// 纯函数版：从设备支持的 ABI 列表里挑发行包 ABI
  @visibleForTesting
  static String? pickReleaseAbi(List<String> deviceAbis) {
    for (final abi in deviceAbis) {
      if (releaseAbis.contains(abi)) return abi;
    }
    return null;
  }

  /// 自动检查更新（应用启动时调用）
  ///
  /// 如果设置中禁用了自动检查，则不执行
  /// 返回 [UpdateInfo] 如果有更新，否则返回 null
  Future<UpdateInfo?> autoCheckUpdate() async {
    if (!getAutoCheckUpdate()) return null;

    try {
      // 自动检查使用缓存
      final updateInfo = await checkForUpdate(useCache: true);
      return updateInfo.hasUpdate ? updateInfo : null;
    } catch (e) {
      // 自动检查失败时静默处理
      return null;
    }
  }

  /// 检查更新
  ///
  /// [useCache] 是否使用缓存，默认 false（手动检查强制刷新）
  /// 返回 [UpdateInfo] 如果检查成功
  /// 抛出异常如果检查失败
  Future<UpdateInfo> checkForUpdate({bool useCache = false}) async {
    final currentVersion = await getCurrentVersion();

    // 检查缓存是否有效
    if (useCache && _prefs != null) {
      final cachedInfo = _getCachedUpdateInfo(currentVersion);
      if (cachedInfo != null) {
        return cachedInfo;
      }
    }

    try {
      final storedEtag = _prefs?.getString(_etagKey);
      var updateInfo =
          await _fetchUpdateInfo(currentVersion, etag: storedEtag);
      if (updateInfo == null && storedEtag != null) {
        // 304 但本地缓存已不在(缓存解析失败、备份恢复只带回了 ETag):
        // 此前这里会把 304 的空 body 当 Release JSON 解析直接抛类型错误,
        // 且 ETag 不清,之后每次手动检查都同样失败。改为丢掉 ETag 全量再取。
        await _prefs?.remove(_etagKey);
        updateInfo = await _fetchUpdateInfo(currentVersion, etag: null);
      }
      if (updateInfo == null) {
        // 不带 If-None-Match 服务端不会回 304,到这里只能是异常情况
        throw Exception('GitHub returned 304 without a cached release');
      }
      return updateInfo;
    } on DioException catch (e) {
      // 403/429 速率限制时尝试使用缓存
      if (e.response?.statusCode == 403 || e.response?.statusCode == 429) {
        final cachedInfo =
            _getCachedUpdateInfo(currentVersion, ignoreExpiry: true);
        if (cachedInfo != null) {
          return cachedInfo;
        }
        throw Exception(S.current.update_rateLimited);
      }
      rethrow;
    }
  }

  /// 请求一次 Release 接口。
  ///
  /// 304 → 返回本地缓存(可能为 null,由调用方决定是否重取);
  /// 200 → 解析并落缓存,**之后**才保存 ETag。顺序不能反:先存 ETag 再解析,
  /// 解析一旦失败就留下一个指向空缓存的 ETag,下次 304 只能报错。
  Future<UpdateInfo?> _fetchUpdateInfo(
    String currentVersion, {
    required String? etag,
  }) async {
    final response = await _dio.get(
      _apiUrl,
      options: Options(
        responseType: ResponseType.json,
        headers: {
          'User-Agent': 'FluxDO-App',
          'Accept': 'application/vnd.github.v3+json',
          if (etag != null) 'If-None-Match': etag,
        },
        validateStatus: (status) =>
            status != null && (status == 200 || status == 304),
      ),
    );

    if (response.statusCode == 304) {
      final cachedInfo =
          _getCachedUpdateInfo(currentVersion, ignoreExpiry: true);
      if (cachedInfo != null) {
        // 内容未变,只续一下缓存时间
        await _prefs?.setInt(
            _cacheTimeKey, DateTime.now().millisecondsSinceEpoch);
      }
      return cachedInfo;
    }

    final data = response.data;
    if (data is! Map) {
      throw Exception('Unexpected GitHub release payload');
    }
    final updateInfo =
        _parseUpdateInfo(Map<String, dynamic>.from(data), currentVersion);
    await _cacheUpdateInfo(updateInfo);

    final newEtag = response.headers.value('etag');
    if (newEtag != null) {
      await _prefs?.setString(_etagKey, newEtag);
    }
    return updateInfo;
  }

  /// 从缓存获取更新信息
  UpdateInfo? _getCachedUpdateInfo(String currentVersion,
      {bool ignoreExpiry = false}) {
    if (_prefs == null) return null;

    final cacheJson = _prefs.getString(_cacheKey);
    final cacheTime = _prefs.getInt(_cacheTimeKey);

    if (cacheJson == null || cacheTime == null) return null;

    // 检查缓存是否过期
    if (!ignoreExpiry) {
      final cacheDate = DateTime.fromMillisecondsSinceEpoch(cacheTime);
      if (DateTime.now().difference(cacheDate) > _cacheValidDuration) {
        return null;
      }
    }

    try {
      final cached =
          UpdateInfo.fromJson(jsonDecode(cacheJson) as Map<String, dynamic>);

      // 重新计算 hasUpdate（因为当前版本可能已变化）
      final hasUpdate = _compareVersions(cached.remoteVersion, currentVersion) > 0;

      return UpdateInfo(
        currentVersion: currentVersion,
        remoteVersion: cached.remoteVersion,
        releaseUrl: cached.releaseUrl,
        releaseNotes: cached.releaseNotes,
        hasUpdate: hasUpdate,
        apkAssets: cached.apkAssets,
      );
    } catch (e) {
      return null;
    }
  }

  /// 缓存更新信息
  Future<void> _cacheUpdateInfo(UpdateInfo info) async {
    if (_prefs == null) return;

    await _prefs.setString(_cacheKey, jsonEncode(info.toJson()));
    await _prefs.setInt(_cacheTimeKey, DateTime.now().millisecondsSinceEpoch);
  }

  /// 解析更新信息
  UpdateInfo _parseUpdateInfo(Map<String, dynamic> data, String currentVersion) {
    // 只去掉前缀 v(上游 tag 习惯);不能 replaceAll,会吃掉 -dev 之类
    // 预发布标识里的字母
    final tagName = data['tag_name'] as String;
    final remoteVersion =
        tagName.startsWith('v') ? tagName.substring(1) : tagName;
    final releaseUrl = data['html_url'] as String;
    var releaseNotes = data['body'] as String? ?? '';

    // 移除 release_template.md 的内容
    // 模板通常以 <div align=center> 开始用于显示下载徽章
    const templateMarker = '<div align=center>';
    final markerIndex = releaseNotes.indexOf(templateMarker);
    if (markerIndex != -1) {
      releaseNotes = releaseNotes.substring(0, markerIndex).trim();
    }

    final hasUpdate = _compareVersions(remoteVersion, currentVersion) > 0;

    // 解析 APK 资源
    final assets = data['assets'] as List<dynamic>? ?? [];
    final apkAssets = _parseApkAssets(assets);

    return UpdateInfo(
      currentVersion: currentVersion,
      remoteVersion: remoteVersion,
      releaseUrl: releaseUrl,
      releaseNotes: releaseNotes,
      hasUpdate: hasUpdate,
      apkAssets: apkAssets,
    );
  }

  /// 解析 GitHub Release 中的 APK 资源
  List<ApkAsset> _parseApkAssets(List<dynamic> assets) {
    final apkAssets = <ApkAsset>[];
    final sha256Map = <String, String>{};

    // 首先收集所有 sha256 文件的下载链接
    for (final asset in assets) {
      final name = asset['name'] as String? ?? '';
      if (name.endsWith('.sha256')) {
        final apkName = name.replaceAll('.sha256', '');
        sha256Map[apkName] = asset['browser_download_url'] as String;
      }
    }

    // 然后解析 APK 文件
    for (final asset in assets) {
      final name = asset['name'] as String? ?? '';
      if (!name.endsWith('.apk')) continue;

      // 从文件名中提取架构
      // 例如：cfluxdo-1.0.0-beta.2-arm64-v8a.apk
      final architecture = _extractArchitecture(name);
      if (architecture == null) continue;

      apkAssets.add(ApkAsset(
        downloadUrl: asset['browser_download_url'] as String,
        sha256Url: sha256Map[name],
        architecture: architecture,
        size: asset['size'] as int? ?? 0,
        name: name,
      ));
    }

    return apkAssets;
  }

  /// 从 APK 文件名中识别 ABI（`cfluxdo-1.1.0-arm64-v8a.apk`）；不是发行 ABI 的文件一律忽略
  @visibleForTesting
  static String? abiOfFileName(String fileName) {
    for (final abi in releaseAbis) {
      if (fileName.endsWith('-$abi.apk')) return abi;
    }
    return null;
  }

  String? _extractArchitecture(String fileName) => abiOfFileName(fileName);

  /// 获取当前设备可安装的 APK 资源：按设备 ABI 优先级，取 Release 里有包的第一个
  Future<ApkAsset?> getMatchingApkAsset(UpdateInfo updateInfo) async {
    List<String> deviceAbis;
    try {
      if (!Platform.isAndroid) return null;
      deviceAbis = (await DeviceInfoPlugin().androidInfo).supportedAbis;
    } catch (e) {
      return null;
    }
    return pickApkAsset(deviceAbis, updateInfo.apkAssets);
  }

  /// 纯函数版：设备声明的 ABI 顺序里，第一个 Release 里有包的
  @visibleForTesting
  static ApkAsset? pickApkAsset(List<String> deviceAbis, List<ApkAsset> assets) {
    for (final abi in deviceAbis) {
      if (!releaseAbis.contains(abi)) continue;
      for (final asset in assets) {
        if (asset.architecture == abi) return asset;
      }
    }
    return null;
  }

  /// 比较两个版本号
  ///
  /// 返回值:
  /// - 正数: v1 > v2
  /// - 0: v1 == v2
  /// - 负数: v1 < v2
  ///
  /// 数字段不限段数(cfluxdo 曾用第 4 段表示基于同一上游版本的修订,
  /// 0.2.28.1);`-` 之后是预发布标识(1.0.0-beta):数字段相同时无标识
  /// 大于有标识,都有标识按 semver 规则比较。非数字段按 0 处理,不抛异常
  /// (1.0.0-beta 之前的版本在这里 int.parse 会炸,手动检查直接报错)。
  int _compareVersions(String v1, String v2) {
    final (numbers1, pre1) = _splitVersion(v1);
    final (numbers2, pre2) = _splitVersion(v2);

    final length =
        numbers1.length > numbers2.length ? numbers1.length : numbers2.length;
    for (int i = 0; i < length; i++) {
      final p1 = i < numbers1.length ? numbers1[i] : 0;
      final p2 = i < numbers2.length ? numbers2[i] : 0;
      if (p1 != p2) return p1.compareTo(p2);
    }
    if (pre1 == null && pre2 == null) return 0;
    if (pre1 == null) return 1;
    if (pre2 == null) return -1;
    return _comparePreRelease(pre1, pre2);
  }

  /// 预发布标识按 semver 规则比较:以 `.` 分段,纯数字段按数值比较且小于
  /// 非数字段,其余按 ASCII;公共前缀相同时段数少的小。
  /// 直接比字符串会得出 beta.10 < beta.2、beta.2 < beta,到 beta.10 或
  /// 正式版 1.0.0 时推送就乱了。
  int _comparePreRelease(String a, String b) {
    final partsA = a.split('.');
    final partsB = b.split('.');
    final length =
        partsA.length < partsB.length ? partsA.length : partsB.length;
    for (var i = 0; i < length; i++) {
      final numA = int.tryParse(partsA[i]);
      final numB = int.tryParse(partsB[i]);
      final int cmp;
      if (numA != null && numB != null) {
        cmp = numA.compareTo(numB);
      } else if (numA != null) {
        cmp = -1;
      } else if (numB != null) {
        cmp = 1;
      } else {
        cmp = partsA[i].compareTo(partsB[i]);
      }
      if (cmp != 0) return cmp;
    }
    return partsA.length.compareTo(partsB.length);
  }

  /// 拆成数字段与预发布标识;`+` 之后的构建号不参与比较。
  (List<int>, String?) _splitVersion(String version) {
    final plus = version.indexOf('+');
    final core = plus == -1 ? version : version.substring(0, plus);
    final dash = core.indexOf('-');
    final numbers = (dash == -1 ? core : core.substring(0, dash))
        .split('.')
        .map((part) => int.tryParse(part) ?? 0)
        .toList();
    final pre = dash == -1 ? null : core.substring(dash + 1);
    return (numbers, pre);
  }
}
