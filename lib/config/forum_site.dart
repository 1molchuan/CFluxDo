/// 仅支持明确适配的论坛，站点身份不依赖可变显示名称。
enum ForumSite {
  linuxDo(
    id: 'linuxdo',
    name: 'LINUX DO',
    baseUrl: 'https://linux.do',
    host: 'linux.do',
    logoAsset: 'assets/images/sites/linuxdo.png',
  ),
  idcFlare(
    id: 'idcflare',
    name: 'IDCFlare',
    baseUrl: 'https://idcflare.com',
    host: 'idcflare.com',
    logoAsset: 'assets/images/sites/idcflare.png',
  );

  const ForumSite({
    required this.id,
    required this.name,
    required this.baseUrl,
    required this.host,
    required this.logoAsset,
  });

  final String id;
  final String name;
  final String baseUrl;
  final String host;
  final String logoAsset;

  bool get isLinuxDo => this == linuxDo;

  /// 旧版数据原地归属 LINUX DO，不让新站读取或覆盖旧站键。
  String storageKey(String legacyKey) =>
      isLinuxDo ? legacyKey : 'site:$id:$legacyKey';

  String accountKey(String accountId) =>
      isLinuxDo ? accountId : '$id::$accountId';

  static ForumSite? fromId(String? id) {
    for (final site in values) {
      if (site.id == id) return site;
    }
    return null;
  }

  /// 只有论坛主域可以按话题或用户 ID 解析，子域不属于论坛路由。
  static ForumSite? fromHost(String host) {
    final normalized = host.toLowerCase();
    for (final site in values) {
      if (site.host == normalized) return site;
    }
    return null;
  }

  static ForumSite? fromUri(Uri uri) {
    if (uri.scheme != 'https' && uri.scheme != 'http') return null;
    final expectedPort = uri.scheme == 'https' ? 443 : 80;
    if (uri.userInfo.isNotEmpty || (uri.hasPort && uri.port != expectedPort)) {
      return null;
    }
    return fromHost(uri.host);
  }
}
