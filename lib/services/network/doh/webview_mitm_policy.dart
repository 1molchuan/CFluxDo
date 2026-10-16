/// WebView 本地代理的 TLS 解密策略。
///
/// 与上游语义一致:启用 DoH 即对 CONNECT 做 MITM 解密(SNI 阻断防护
/// 依赖改写出口 TLS;纯隧道保持端到端 TLS 会暴露真实 SNI,直连必被阻断)。
/// 曾试验过 Windows 高性能模式走端到端隧道,实测直连不可用,已回退。
class WebViewMitmPolicy {
  const WebViewMitmPolicy._();

  static bool useMitmConnect({
    required bool isWindows,
    required bool webViewAdapterEnabled,
  }) => true;

  static bool useGatewayMode({
    required bool isWindows,
    required bool dohEnabled,
    required bool gatewayEnabled,
    required bool webViewAdapterEnabled,
  }) => dohEnabled && gatewayEnabled;

  /// 是否要先把 CA 装进系统信任库才能启动网关。上游 Windows 要求装进用户根信任库
  /// （作用于所有应用）；cfluxdo 改为 WebView2 启动参数只信任设备 CA 的公钥，
  /// 不再需要系统级信任，所以恒为 false
  static bool requiresTrustedCa({
    required bool isWindows,
    required bool dohEnabled,
    required bool webViewAdapterEnabled,
  }) => false;
}
