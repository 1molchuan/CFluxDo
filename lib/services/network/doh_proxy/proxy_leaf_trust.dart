import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../network_logger.dart';
import 'doh_proxy_ffi.dart';

/// 桌面端 WebView 对本地代理证书的信任（不对任何证书错误盲放行）。
///
/// Windows（WebView2）在创建环境时用 `--ignore-certificate-errors-spki-list`
/// 只信任设备 CA（见 WindowsWebViewEnvironmentService），正常不会触发证书错误；
/// 万一触发，也和 Linux 一样只认代理签发的那张叶子。
///
/// Linux（WPE WebKit）：WebView 经本地 MITM 代理连 linux.do 时，代理用设备 CA 现签叶子证书。WPE 没有
/// 「额外信任某个 CA」的接口，所以不信任 CA，而是逐主机放行代理签发的**那一张**
/// 叶子证书（WebKit 按证书内容精确比对）：
/// - 已知主机在代理启动后预先放行（子资源证书出错时 WebKit 不回调，只能预放）；
/// - 其余主机的主文档出错时，比对证书与代理为该主机签发的叶子是否完全一致，
///   一致才放行，否则按证书错误处理。
///
/// 代理只对 [mitmHosts] 范围做 MITM，范围外的主机走隧道、由系统证书库端到端校验。
class ProxyLeafTrust {
  ProxyLeafTrust._();

  static const _channel = MethodChannel('cfluxdo/wpe_tls');

  /// 必须经 ECH 的主机（后缀匹配），传给代理作为 MITM 范围
  static const mitmHosts = ['linux.do', 'idcflare.com'];

  /// 代理启动后预先放行的主机：linux.do 主站与 App 里出现过的子域
  static const _preallowHosts = [
    'linux.do',
    'www.linux.do',
    'cdn.linux.do',
    'cdn3.linux.do',
    'connect.linux.do',
    'credit.linux.do',
    'cdk.linux.do',
    'ping.linux.do',
    'auth.linux.do',
    'linuxdo-uploads.s3.linux.do',
    'idcflare.com',
    'www.idcflare.com',
  ];

  /// 证书出错时按「是否代理签发的那张叶子」裁定（Linux / Windows）
  static bool get isApplicable => Platform.isLinux || Platform.isWindows;

  /// 预先放行只有 WPE 需要（插件补丁里的通道）
  static bool get _needsPreallow => Platform.isLinux;

  /// 代理（重新）启动后调用：代理每次启动叶子都会换，要整批重新放行
  static Future<void> preallowProxyLeaves() async {
    if (!_needsPreallow) return;
    var ok = 0;
    for (final host in _preallowHosts) {
      final pem = DohProxyFfi.instance.mitmLeafPem(host);
      if (pem == null) continue;
      try {
        await _channel.invokeMethod<bool>('allowTlsCertificateForHost', {
          'host': host,
          'pem': pem,
        });
        ok++;
      } catch (e) {
        debugPrint('[ProxyLeafTrust] 放行 $host 失败: $e');
      }
    }
    NetworkLogger.log('[ProxyLeafTrust] 已预先放行 $ok/${_preallowHosts.length} 个主机的代理叶子证书');
  }

  /// 主文档证书出错时的判定：[der] 与代理为 [host] 签发的叶子完全相同才返回 true
  static bool isProxyLeaf(String host, Uint8List? der) {
    if (!isApplicable || der == null || der.isEmpty) return false;
    final pem = DohProxyFfi.instance.mitmLeafPem(host.toLowerCase());
    if (pem == null) return false;
    final expected = pemToDer(pem);
    final same = expected != null && listEquals(expected, der);
    NetworkLogger.log('[ProxyLeafTrust] $host 主文档证书出错，与代理叶子${same ? '一致，放行' : '不一致，拒绝'}');
    return same;
  }

  @visibleForTesting
  static Uint8List? pemToDer(String pem) {
    final body = pem
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty && !l.startsWith('-----'))
        .join();
    try {
      return base64.decode(body);
    } on FormatException {
      return null;
    }
  }
}
