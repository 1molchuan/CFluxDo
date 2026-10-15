# cfluxdo Linux 桌面端设计（草案，2026-10-15 夜）

> 状态：设计 + 可行性验证。代码都在本地分支 `desktop/linux`（主仓库 6 个提交，含本文；子模块 `core/doh_proxy` 本地分支 `desktop/linux` 1 个提交），**没有推送、没有发布**，`cfluxdo` / `main` 分支没动。
> 下面每条决定都写了理由和「什么情况下推翻」，不同意的直接划掉。

## 0. 结论

1. **能做，而且主链路已经跑通。** 今晚在本机的 Debian 13 chroot 里编出了 Linux 版。它能启动，也能用游客模式刷「最新」、点开帖子看详情。内置 WebView 经本地代理走 ECH 过了 CF 人机验证，`cf_clearance` 落进了 Cookie 罐。本地动态优选在 Linux 上也跑起来了：赢家 14 ms，来源 atlas。
2. **最大的安全问题有了比上游更好的解法。** 上游在 Linux 上的做法是：证书出错一律放行，等于 WebView 不校验证书。这里改成只放行本地代理给某个主机签发的那一张叶子证书。WebKit 按证书内容逐字节比对，换一张证书，哪怕是同一个 CA 签的，也会照常报错。而且只有 `linux.do` 这一系主机走中间人，其他主机走隧道，由系统证书库端到端校验。
3. **首发形态：Flatpak，x86_64。** 理由见 D1。
4. **前置条件：先做架构体检的 #3（Dart↔Rust 单一通道）**，再把这个分支合进主线；#4 不是前置。理由见 §4。

## 1. 今晚的实验与证据

| 实验 | 结果 | 证据 |
|---|---|---|
| Rust 连接层编成 Linux 动态库 | `libdoh_proxy.so` 10.7 MB，最低 glibc 2.34；Python ctypes 进程内启动，`linux.do` ECH **Accepted** | `/root/linux-spike/run_proxy.py`、`proxy.log` |
| WPE 证书策略（独立 C 程序，WPE 2.48.3） | 默认策略（出错即失败）：`UNKNOWN_CA` 失败 ✅；**预先放行叶子**：页面正常加载，策略仍是「出错即失败」✅；出错后比对再放行：比对一致 → 放行重载 ✅；盲放行作对照 | `/srv/trixie/spike/wpe_trust.c`、`shot_allow.png` |
| Flutter Linux 编译 | Debian 13 + WPE 2.48.3（发行版包，没有 WPEPlatform，插件自动退到 WPEBackend-FDO）；改 2 处后编过；bundle 259 MB，其中 WPE 113 MB | `build/linux/x64/release/bundle` |
| App 实跑（Xvfb） | 启动 → CF 验证页（WebView 经代理：`linux.do` 走 MITM，`challenges.cloudflare.com` 走隧道）→ 点勾选框 → `cf_clearance` 进罐 → 游客模式列表、帖子详情（代码高亮、头像）正常；10/10 个主机的叶子预放行，没有走「出错再比对」的兜底 | `/root/linux-spike/run4_*.png`、`app_log.jsonl` |
| 本地优选 | `select: winner 172.64.145.202 14 ms source=Atlas`（32 个候选，4/4 通过） | `app_*.log` |
| 回归 | Rust 全量 64 通过；新增 Dart 测试 3 通过；`flutter analyze` 与 `cfluxdo` 分支同为 66 条（无新增） | — |

实跑时顺带发现并修掉的三个 Linux 专属问题：
- **启动卡死。** 没有系统 D-Bus 时，`connectivity_plus` 把错误抛在内部订阅里，`checkConnectivity()` 永远不返回，`main()` 卡在 `runApp` 之前，窗口一直是黑的。
- **数据目录不对。** `getApplicationDocumentsDirectory()` 在 Linux 上是用户的「文档」文件夹，没配 XDG 用户目录时还会直接抛异常，结果 Cookie 罐、数据库和日志都起不来。
- **窗口不显示。** 上游的 runner 要等 `window_manager` 在 Dart 侧显示窗口，cfluxdo 已经去掉了这个依赖，窗口就永远不出来。

## 2. 总体结构

```
┌──────────── 同一套 Dart / Flutter UI（桌面已有主从布局、快捷键、中键）────────────┐
│ Dio ──(明文 HTTP 改写)──► Rust 网关 libdoh_proxy.so（进程内 FFI）──ECH──► CF ──► linux.do │
│ WPE WebView ──CONNECT──► 同一个网关                                                 │
│      ├─ *.linux.do        → MITM（叶子证书逐主机精确放行）→ ECH                      │
│      └─ 其他主机 / CF 验证 → 隧道（DoH 解析 + 原样转发，系统证书库校验）              │
└────────────────────────────────────────────────────────────────────────────────────┘
```

Android 侧行为不变。所有新分支都用 `Platform.isLinux` 或「MITM 范围为空 = 不限」来区分，Android 走的还是原来的路径。

## 3. 关键决定

### D1 只做 Linux x86_64，首发只出 Flatpak
- **理由**：WPE 不是一个能随包带走的库。`libWPEWebKit` 运行时要按编译期的绝对路径去找 `WPEWebProcess`、`WPENetworkProcess` 和注入模块。今晚的 bundle 把 113 MB 的 `libWPEWebKit` 拷进了 `lib/`，但辅助进程用的还是系统里的那一份，换个发行版或版本就会坏。Flatpak 能把 WPE 和应用一起封进去，所有发行版拿到的都是同一个版本，上游也是这么发的（上游 0.2.28 的 `.flatpak` 132 MB）。
- **代价**：用户要先装 Flatpak 和 GNOME 运行时（只装一次）。WPE 要自己编，一次要几个小时，所以单独做成「WPE 层」，只在升级 WPE 时重编（沿用上游的 `flatpak-wpe-layer` 做法）。
- **不做的**：AppImage 和官方 deb。AppImage 带不走 WPE，WebKit 只有开发者模式才认 `WEBKIT_EXEC_PATH`。deb 要绑死发行版的 WPE 版本。Debian 13、Arch、Fedora 这类自带 WPE ≥ 2.48 的发行版，可以写文档让人从源码编，不当正式渠道。
- **推翻条件**：如果有人愿意维护某个发行版的包，再按需加。

### D2 WebView 用 WPE（`flutter_inappwebview_linux`），插件内置一份并打补丁
- **理由**：现有 25 个文件都依赖 `flutter_inappwebview`，Linux 实现官方背书的就是这个插件。今晚验证过：代理、Cookie、执行 JS、输入转发、无头 WebView 都能用。
- **补丁**（见 `packages/flutter_inappwebview_linux/CFLUXDO_PATCHES.md`）：① `get_theme_color` 是 WPE 2.50 才有的接口，加版本判断；② 新增 `cfluxdo/wpe_tls` 通道（见 D3）。原样副本和补丁分成两个提交，升级插件时好对比。
- **推翻条件**：插件上游合入了「预先放行证书」的接口，就删掉补丁②。

### D3 证书：逐主机精确放行叶子证书；只对 `linux.do` 系做 MITM
- **现状问题**：`WebViewSettings.handleServerTrustAuthRequest` 在网关模式下对**任何**证书都放行。Android 靠 `network_security_config` 只信任自家 CA，这个放行在 Android 上没有实际后果；Linux 没有对应机制，照搬就等于完全不校验。
- **做法**：
  1. Rust：配置项 `mitm_hosts`（后缀匹配，默认空 = 现状），Linux 传 `["linux.do"]`；范围外的主机走隧道。新增 FFI `doh_proxy_mitm_leaf_pem(host)`，返回本实例给这个主机签发的叶子证书（同一实例对同一主机永远是同一张，有测试）。
  2. 插件：`allowTlsCertificateForHost(host, pem)` → `webkit_network_session_allow_tls_certificate_for_host`。
  3. Dart：`WpeTlsTrust`。每次给 WebView 设代理时，先给已知的 10 个 `linux.do` 子域预放行。子资源证书出错时 WebKit 不会回调，所以只能预放。主文档出错时，比对证书 DER 和代理签发的那张，一致才放行，否则拒绝。
- **为什么不是「信任我们的 CA」**：WPE 没有这个接口。改系统或用户级 p11-kit 信任库会让本机其他程序也信任这个 CA，风险外溢。
- **已知局限**：未预放行的 `*.linux.do` 子域，如果第一次就以子资源的形式出现，会静默失败一次（主文档能走比对兜底）。办法是补进预放行表，代理第一次给新主机签证书时也会留日志。
- **代价**：代理每次重启叶子都会换，所以每次设代理都要重放一遍，已经接在 `_setWebViewProxy` 里。

### D4 Rust 连接层走进程内 FFI，删掉进程模式
- **理由**：1.1 的本地优选、换网通知、加速授权、CA 生成都只有 FFI 版本，进程模式（`doh_proxy_bin`）缺的太多。今晚 FFI 在 Linux 上一次就跑通了。
- **改动**：`isAvailable` 加 Linux；按 `<可执行文件目录>/lib/libdoh_proxy.so` 的绝对路径加载；`native:prepare linux` 改成编 `--lib`，CMake 把它装进 bundle。进程模式的代码等 Linux 稳定后单独删。

### D5 数据目录用 XDG 数据目录，不用「文档」
- `getAppDataDirectory()`：Linux 上返回 `~/.local/share/com.github.molchuan.cfluxdo`，在 Flatpak 里自动落到 `~/.var/app/...`；Android 上仍是原来的目录，不迁移。改了 7 个调用点和 `ai_model_manager` 包里 1 处。
- **推翻条件**：没有。Linux 上只能这样。

### D6 名字与标识
- 可执行文件 `cfluxdo`，应用 ID `com.github.molchuan.cfluxdo`，和 Android 包名一致，`.desktop` 文件名也用应用 ID（Flatpak 与 app_links 都要求这样）。

### D7 连接层产品决定与 Android 一致
- 本地优选默认开（atlas 参与竞速），探针上报默认关、首次启动弹隐私说明，都照 1.1.0 已经定下的来（见 2026-10-14 的产品决定）。`selectorEligible` 已经放开 Linux。

### D8 机密存储：系统 Secret Service，没有就只放内存
- 现有的 `ResilientSecureStorage` 已经是这个策略：不降级成明文。GNOME 和 KDE 自带 Secret Service；精简桌面没有，App 每次重启都要重新授权 cfhub / 加速。Linux 上检测到没有 Secret Service 时，在设置页提示一句。
- **推翻条件**：如果用户普遍在没有密钥环的环境下用，再考虑「用户口令加密的文件」，但不做明文。

### D9 网络变化：NetworkManager，没有就按「已连接」
- Flatpak 里只开 `--system-talk-name=org.freedesktop.NetworkManager`，不开上游那种整条 `--socket=system-bus`（权限太大）。拿不到网络签名时就没有「换网即重选」，靠优选自己的周期重选兜底。

### D10 深链与登录
- 主登录路径用内置 WebView 登录页（经代理，D3 生效），不依赖系统浏览器回跳。
- `fluxdo://`、`discourse://` 按 app_links 的 Linux 文档改成单实例：`G_APPLICATION_HANDLES_COMMAND_LINE | G_APPLICATION_HANDLES_OPEN`。这样 App 已经开着时，链接会转给现有窗口。**不接管 `https://`**，上游的 `.desktop` 注册了 https，会抢走系统浏览器的所有链接，已删。

### D11 音视频：Linux 用 media_kit，Android 不动
- `video_player` 和 `just_audio` 都没有 Linux 实现。Linux 改用 `media_kit`（libmpv），Android 继续用现在的库，中间加一层「播放器会话」接口，两边各一个适配器。这是 Phase 2 最大的一块；在那之前，Phase 1 先把 Linux 上的视频和音频楼层降级成「在浏览器中打开」。
- **推翻条件**：如果 `media_kit` 在 Android 上也稳定，可以统一成一套，但不在这次范围里。

### D12 后台与通知
- 不做常驻后台。App 开着时照常轮询，用系统通知提醒（`flutter_local_notifications` 有 Linux 实现）。审计显示 `flutter_foreground_task` 的调用没有平台判断，Linux 上会抛 `MissingPluginException`，要补判断。托盘图标放 Phase 3，看有没有需求。

### D13 更新
- Release 增加 `cfluxdo-<版本>-linux-x86_64.flatpak`，附 `.sha256`。在 Linux 上，App 内的「检查更新」只负责提示和打开下载页，不自动安装（单文件 flatpak 没法原地升级）。以后可以考虑在 GitHub Pages 上挂一个 Flatpak 仓库，让 `flatpak update` 直接可用。
- `UpdateService` 现在只认 `.apk`，要按平台挑资产。老版本 Android 客户端只解析 `.apk` 资产，新增 `.flatpak` 不会被它们误选，但发版前要再核对一次。

### D14 Linux 上隐藏的功能
- 应用图标切换、渲染后端切换（Skia/GLES）、HyperOS 适配、预测性返回、扫码登录（没有摄像头插件）、passkey、保存到相册、`open_filex`（改用 `xdg-open`）。这些都已有平台判断或按审计清单补判断。

## 4. 与架构体检 #3 / #4 的关系

- **#3（Dart↔Rust 单一通道）应该先做。** Linux 已经把问题放大了：启动配置 30 多个参数，要穿过 `NetworkSettingsService` → `DohProxyService`（3 个调用点）→ `DohProxyFfi.start` 逐个透传。今晚为了不改这条链，`mitm_hosts` 是在 FFI 层按平台补的默认值，这是权宜之计。合进主线前，应该把「平台网络档案」（MITM 范围、要不要优选、WebView 怎么设代理）收成 #3 里的一个对象，Android 和 Linux 各一份。
- **#4（加速线路交给 Rust 决定）不是前置。** 它和平台无关，Linux 与 Android 同样受益，先后都行。

## 5. 分阶段计划

| 阶段 | 内容 | 验收 | 估计 |
|---|---|---|---|
| **0 可行性**（已完成） | 本文 + `desktop/linux` 分支 | 见 §1 | — |
| **1 能用** | #3 收口；登录（WebView 登录页、`_t` 同步、`SessionTokenAuthority`）在 WPE 上走一遍；`flutter_foreground_task` 等调用补平台判断；单实例 + 深链；Secret Service 提示；回归 13 条基线外无新增失败 | 真机桌面（GNOME / KDE 各一台）登录、发帖、回复、通知、换网后自动重选 | 3–5 天 |
| **2 好用** | media_kit 播放器适配；窗口大小与位置记忆（不引回 `window_manager` 也能做，GTK 侧存）；中文输入法在 WebView 里的表现；HiDPI；快捷键核对 | 视频/音频楼层可播；4K 屏缩放正常 | 3–5 天 |
| **3 发布** | WPE 层换到当前受支持的 GNOME 运行时（上游用的 48 已过支持期），WPE 用当时最新稳定版并开启 WPEPlatform；Flatpak 清单与 CI；Release 资产；`UpdateService` 按平台挑资产；README | `flatpak install cfluxdo.flatpak` 后在 Debian、Ubuntu、Fedora、Arch 上都能启动 | 2–3 天 + WPE 层编译时间 |

## 6. 风险与还没验证的事

1. **真实桌面上的 WPE**：GPU、Wayland、HiDPI、输入法都还没验证。今晚的环境是 Xvfb 加软件渲染，WebProcess 退出时有一条 `epoxy` 断言（没有 GL 上下文），没影响功能。插件有虚拟机和无 GPU 时自动切软件渲染的逻辑。
2. **Turnstile**：在机房 IP、Xvfb 环境下用 `xdotool` 点，第二次才过。真实桌面和住宅 IP 要实测。
3. **WebKit 沙箱**：在 chroot 里必须关掉，上游的 Flatpak WPE 层也关了 bubblewrap 沙箱。Flatpak 本身是一层沙箱，但 WebKit 的进程级隔离没了。Phase 3 评估能不能用 Flatpak 的子沙箱。
4. **秘密与登录态**：Linux 上 `_t` 在 Cookie 罐里，罐是明文 JSON，和 Android 一样只靠目录权限保护。桌面上同用户的其他进程都能读，要在 README 里写清楚。
5. **代理热重启**：叶子证书随实例变化。所有「重启代理」的路径都要确认最后会走到 `_setWebViewProxy`。今晚只验证了冷启动。
6. **127.0.0.1 自请求噪音**：启动约 2 秒后，网关会收到一次发给自己（`127.0.0.1:<端口>` 和 `localhost:<端口>`）的明文请求，转发失败，日志里留两行 WARN。不影响功能，Android 上可能也有，来源待查。
7. **字体**：GNOME 运行时自带的中文字体覆盖面要在 Flatpak 里核对，今晚的 chroot 装的是 `fonts-noto-cjk`。
8. **无痕 WebView**：用的是临时网络会话，不吃代理，也不吃放行表。现在代码里没用到，以后也别用。

## 7. 怎么复现

```bash
# 宿主机：准备原生库（在 worktree 里）
cd /root/fluxdo-linux && dart tool/project_tasks.dart native:prepare linux release
# chroot（Debian 13，含 WPE 2.48 / GTK3 / clang / Xvfb）
/root/linux-spike/chroot_env.sh mount
/root/linux-spike/chroot_env.sh run 'cd /root/fluxdo-linux && flutter build linux --release'
/root/linux-spike/run_app.sh 35 shot      # Xvfb 里启动并截图
/root/linux-spike/chroot_env.sh umount    # 用完一定要卸载绑定挂载
```

## 8. 改动清单（`cfluxdo..desktop/linux`）

- `linux/`：从上游 `323608c4^` 恢复，改名，去掉 ffmpeg 下载，装入 `libdoh_proxy.so`，首帧后显示窗口，`.desktop` 去掉 https。
- `packages/flutter_inappwebview_linux/`：原样副本 + 2 处补丁。
- `core/doh_proxy`（子模块）：`mitm_hosts`、`doh_proxy_mitm_leaf_pem`、叶子证书缓存在写锁内签发（并发首握不会签出两张），2 个新测试。
- Dart：`wpe_tls_trust.dart`（新）、`app_data_dir.dart`（新）、`doh_proxy_ffi.dart`、`network_settings_service.dart`、`webview_settings.dart`、`connectivity_service.dart`，以及 7 个数据目录调用点。
- `tool/project_tasks.dart`：Linux 原生产物改成 `libdoh_proxy.so`。
- 测试：`test/services/wpe_tls_trust_test.dart`。
