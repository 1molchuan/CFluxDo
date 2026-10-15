# cfluxdo 对 flutter_inappwebview_linux 0.1.0-beta.1 的改动

基线：pub.dev 上的 `flutter_inappwebview_linux 0.1.0-beta.1`（去掉了 example/）。

1. `linux/in_app_webview/in_app_webview.cc`：`webkit_web_view_get_theme_color` 是 WPE 2.50
   新增的，用 `WEBKIT_CHECK_VERSION(2, 50, 0)` 包起来，旧版本 WPE（Debian 13 的 2.48）也能编译。
2. 新增 `linux/cfluxdo_tls_channel.{h,cc}` 并在插件注册时调用：`cfluxdo/wpe_tls` 通道的
   `allowTlsCertificateForHost({host, pem})`，把本地代理为该主机签发的叶子证书放进默认网络
   会话的允许表。用来替代「证书出错就 PROCEED」的盲放行。

升级插件版本时逐条核对上面的改动是否还需要。
