/// 应用内更新下载 APK 的候选线路：GitHub 直连 + 几个公共反代镜像。
///
/// 2026-11 佬友反馈：国内很多网络直连 GitHub 下载 Release 卡在 0% 然后
/// 失败，只能去网页手动下。下载前对这些线路测速、挑最快的，卡住自动换下一
/// 条（见 MirroredApkDownloader）。
///
/// 列表 2026-11-18 实测过（VPS 与国内家宽各拉一次前 64 KB）：能拿到 APK
/// 的才留下。公共镜像来来去去，失效的会在测速时被跳过；拿到的内容一律按
/// GitHub 接口给的 SHA-256 校验，镜像动过手脚装不上。
library;

/// 一条下载线路
class DownloadRoute {
  const DownloadRoute({
    required this.label,
    required this.url,
    this.official = false,
    this.userConfigured = false,
  });

  /// 给人看的名字（域名）
  final String label;
  final String url;

  /// GitHub 官方直连
  final bool official;

  /// 用户在「GitHub 反代加速」里自己填的
  final bool userConfigured;

  @override
  String toString() => 'DownloadRoute($label)';
}

abstract final class GithubMirrorPolicy {
  static const _githubPrefix = 'https://github.com/';

  /// 前缀式镜像：前缀 + 完整的 github.com 链接（gh-proxy 系通用格式）
  static const prefixMirrors = [
    'https://gh-proxy.com/',
    'https://ghfast.top/',
    'https://ghproxy.net/',
    'https://gh-proxy.org/',
    'https://v6.gh-proxy.org/',
    'https://ghproxy.imciel.com/',
  ];

  /// 路径式镜像：把 `https://github.com` 换成这个前缀
  static const pathMirrors = ['https://xget.xi-xu.me/gh'];

  static bool isGithubUrl(String url) => url.startsWith(_githubPrefix);

  /// [original] 的全部候选线路：用户自己填的反代在最前，然后是官方直连和
  /// 内置镜像。不是 github.com 的链接只有它自己。
  ///
  /// [allowPublicMirrors] 为 false 时（拿不到可信的校验值）只留用户自己填的
  /// 和官方直连：公共镜像给的内容没法核对，不能拿来装。
  static List<DownloadRoute> routes(
    String original, {
    String userProxy = '',
    bool allowPublicMirrors = true,
  }) {
    if (!isGithubUrl(original)) {
      return [DownloadRoute(label: _host(original), url: original)];
    }
    final routes = <DownloadRoute>[];
    final seen = <String>{};
    void add(DownloadRoute route) {
      if (seen.add(route.url)) routes.add(route);
    }

    final proxy = _normalizePrefix(userProxy);
    if (proxy.isNotEmpty) {
      add(
        DownloadRoute(
          label: _host(proxy),
          url: '$proxy$original',
          userConfigured: true,
        ),
      );
    }
    add(DownloadRoute(label: 'github.com', url: original, official: true));
    if (allowPublicMirrors) {
      for (final prefix in prefixMirrors) {
        add(DownloadRoute(label: _host(prefix), url: '$prefix$original'));
      }
      final path = original.substring(_githubPrefix.length - 1);
      for (final base in pathMirrors) {
        add(DownloadRoute(label: _host(base), url: '$base$path'));
      }
    }
    return routes;
  }

  static String _normalizePrefix(String raw) {
    var url = raw.trim();
    if (url.isEmpty) return '';
    if (!url.endsWith('/')) url = '$url/';
    return url;
  }

  static String _host(String url) => Uri.tryParse(url)?.host ?? url;
}
