# cfluxdo 对 flutter_inappwebview_linux 0.1.0-beta.1 的改动

基线：pub.dev 上的 `flutter_inappwebview_linux 0.1.0-beta.1`（去掉了 example/）。

1. `linux/in_app_webview/in_app_webview.cc`：`webkit_web_view_get_theme_color` 是 WPE 2.50
   新增的，用 `WEBKIT_CHECK_VERSION(2, 50, 0)` 包起来，旧版本 WPE（Debian 13 的 2.48）也能编译。
2. 新增 `linux/cfluxdo_tls_channel.{h,cc}` 并在插件注册时调用：`cfluxdo/wpe_tls` 通道的
   `allowTlsCertificateForHost({host, pem})`，把本地代理为该主机签发的叶子证书放进默认网络
   会话的允许表。用来替代「证书出错就 PROCEED」的盲放行。

3. `cfluxdo_enable_persistent_cookies()`（同文件，插件注册时调用）：默认网络会话的 Cookie
   持久化到 `<XDG 数据目录>/<程序名>/cookies.sqlite`。WPE 默认不落盘，重启后 WebView 里没有
   CF 签发的 `cf_clearance`，而 App 只让 `cf_clearance` 从 WebView 流向本地 jar，结果每次冷启动
   都要重新过人机验证。

4. `InAppWebView::OnWpePlatformBufferRendered`（WPEPlatform 路径）：原版不管走哪条渲染路径，都把
   当前 `WPEBuffer` 的裸指针（不加引用）留到下一帧才 `wpe_view_buffer_released`。软件渲染（SHM）下
   WebKit 重建交换链会先销毁旧缓冲区，下一帧 `WPE_IS_BUFFER(previous_buffer)` 读到野指针，Flatpak
   （GNOME 48 + WPE 2.48.7 带 WPEPlatform）启动一两秒内稳定 SIGSEGV。改成：SHM / 通用像素导入已经
   拷走像素，当帧就还；只有 EGL 零拷贝路径留到下一帧，并且持有一个引用。上游 fluxdo 450c00ef 也做了
   同样的「只有 EGL 路径保留」。

5. 新增 `linux/cfluxdo_render_mode.{h,cc}`，取代上游的 `ApplySoftwareRenderingIfNeeded()`：
   决定网页进程（WPEWebProcess）用硬件还是软件渲染。上游把 NVIDIA 专有驱动当「已知可用」，
   网页进程拿到 NVIDIA 渲染节点走 GBM / EGL，在 `libnvidia-eglcore` 里 SIGSEGV（Kubuntu 26.04 +
   615.71 实测：登录页、人机验证页全黑，换 Intel 核显正常）。
   - 自动判定顺序：上次硬件下网页进程崩过 → 渲染节点有 `nvidia` 驱动 → 没有渲染节点 → 已设
     `LIBGL_ALWAYS_SOFTWARE` → 上游的虚拟机判定 → 硬件。
   - 软件 = `LIBGL_ALWAYS_SOFTWARE=1`（WPEPlatform 不交渲染节点，帧走 SHM）+
     `__EGL_VENDOR_LIBRARY_FILENAMES=<Mesa 厂商文件>`（glvnd 不加载 NVIDIA）+
     `WEBKIT_SKIA_ENABLE_CPU_RENDERING=1`。主界面的 GL 在注册插件前已初始化，不受影响。
   - 崩溃自愈：`InAppWebView::OnWebProcessTerminated` 里 `didCrash` 时调
     `cfluxdo_render_mode_on_web_process_crashed()`，「自动 + 硬件」下记下崩溃，下次启动改软件，
     并经 `cfluxdo/wpe_render` 通道通知 Dart 弹提示。
   - 设置：`cfluxdo/wpe_render` 的 `getState` / `setMode(auto|hardware|software)`，存在
     `<XDG 配置目录>/<程序名>/webview_render_mode`；`CFLUXDO_WEBVIEW_RENDERING=hardware|software`
     优先于一切。都是下次启动生效（WebKit 只取一次渲染节点）。

升级插件版本时逐条核对上面的改动是否还需要。

另：runner（`linux/runner/my_application.cc`）改成单实例（`G_APPLICATION_HANDLES_COMMAND_LINE`，
`local_command_line` 返回 FALSE），浏览器授权登录回跳 `discourse://auth_redirect` 才能转给正在运行
的实例；原模板 `G_APPLICATION_NON_UNIQUE` 每次回跳都新开一个进程，链接谁也收不到。
