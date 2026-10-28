import 'doh/network_settings_service.dart';

/// 交给播放器的媒体地址。
///
/// 视频 / 音频由播放器自己联网（Android 的 ExoPlayer、桌面的 mpv），不经过
/// Dart 侧的网关适配器：直连 CDN 是明文 SNI，国内对 linux.do 系域名
/// （cdn.ldstatic.com 等）直接重置，表现就是视频一直转圈放不出来。
/// 网关模式下把地址改写成本机网关 + `Host` 头，和图片走同一条路：覆盖域名
/// 用优选赢家 IP + ECH，其余域名按 DoH 解析。
class GatewayMediaSource {
  const GatewayMediaSource(this.uri, this.headers);

  final Uri uri;

  /// 要随请求带上的头（改写时是 `Host`）
  final Map<String, String> headers;

  /// 是否改写成了走本机网关
  bool get viaGateway => headers.isNotEmpty;

  /// 不改写，原样直连
  static GatewayMediaSource direct(String url) =>
      GatewayMediaSource(Uri.parse(url), const {});

  /// 排查「视频放不出来」用：当前网络设置里决定改不改写的几项
  static Map<String, Object?> diagnostics() {
    final settings = NetworkSettingsService.instance;
    return {
      'gatewayMode': settings.isGatewayMode,
      'dohEnabled': settings.current.dohEnabled,
      'gatewayEnabled': settings.current.gatewayEnabled,
      'hasProxyPort': settings.current.proxyPort != null,
    };
  }

  /// 按当前网络设置改写 [url]；不在网关模式或地址不适合改写时原样返回。
  static GatewayMediaSource resolve(String url) {
    final settings = NetworkSettingsService.instance;
    return rewrite(
      Uri.parse(url),
      gatewayMode: settings.isGatewayMode,
      port: settings.current.proxyPort,
    );
  }

  /// [resolve] 的纯函数部分：只改写默认端口、不带账号信息的 https 地址。
  static GatewayMediaSource rewrite(
    Uri uri, {
    required bool gatewayMode,
    required int? port,
  }) {
    if (!gatewayMode ||
        port == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        (uri.hasPort && uri.port != 443)) {
      return GatewayMediaSource(uri, const {});
    }
    return GatewayMediaSource(
      Uri(
        scheme: 'http',
        host: '127.0.0.1',
        port: port,
        path: uri.path,
        query: uri.query.isEmpty ? null : uri.query,
      ),
      {'Host': uri.host},
    );
  }
}
