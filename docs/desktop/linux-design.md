# cfluxdo Linux 桌面端设计（草案，2026-10-15 夜）

> 状态：设计 + 可行性验证。代码都在本地分支 `desktop/linux`（主仓库 9 个提交，含本文；子模块 `core/doh_proxy` 本地分支 `desktop/linux` 1 个提交），**没有推送、没有发布**，`cfluxdo` / `main` 分支没动。
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
| 回归 | Rust 全量 64 通过；Flutter 全量 1400 通过，失败的只有 13 条已知基线（另有 5 个文件在整批跑时加载失败或抖动，单独重跑全部通过）；新增 Dart 测试 3 条；`flutter analyze` 与 `cfluxdo` 分支同为 66 条（无新增） | `/tmp/linux_branch_fulltest.log` |

实跑时顺带发现并修掉的三个 Linux 专属问题：
- **启动卡死。** 没有系统 D-Bus 时，`connectivity_plus` 把错误抛在内部订阅里，`checkConnectivity()` 永远不返回，`main()` 卡在 `runApp` 之前，窗口一直是黑的。
- **数据目录不对。** `getApplicationDocumentsDirectory()` 在 Linux 上是用户的「文档」文件夹，没配 XDG 用户目录时还会直接抛异常，结果 Cookie 罐、数据库和日志都起不来。
- **窗口不显示。** 上游的 runner 要等 `window_manager` 在 Dart 侧显示窗口，cfluxdo 已经去掉了这个依赖，窗口就永远不出来。

### 1.1 2026-10-16 登录实测（出口走用户 Mac，`loc=CN`，直连 linux.do 会被掐断）

环境：App 以独立用户运行，TCP 经 redsocks 转到用户 Mac 的网络出口；画面经 VNC 映射到 Mac，有 gnome-keyring。

| 项目 | 结果 |
|---|---|
| 国内出口连 linux.do | ECH Accepted，本地优选正常 |
| 登录页（内置浏览器）| CF 验证、hCaptcha 拼图都能正常显示和操作；用邮箱一次性代码登录成功 |
| 登录完成检测 | ❌→已修：验证码登录成功后 Discourse 只在页面内切换路由，WPE 不上报，页面停在网页上，手动刷新才能检测到。改为 Linux 上每 2 秒检查一次（未用新登录复测） |
| 冷启动 | ❌→已修：WPE 默认不把 Cookie 写盘，重启后 WebView 里没有 `cf_clearance`（App 只让它从 WebView 流向 jar），每次冷启动都弹人机验证。插件补丁 3 让 WebView Cookie 持久化，修后连续冷启动 2 次都不弹验证，登录保持 |
| `_t` 轮换 | 挂机 17 分钟没有请求就不轮换；第一次请求就轮换，jar 与 WebView 磁盘上的值一致；轮换后冷启动登录保持 |
| 登录后页面 | 通知、个人页、书签、内置浏览器（已登录态）都正常 |
| 密钥环 | gnome-keyring 解锁时不再出现 `KeyringLocked`（空口令建不出 login 密钥环，测试用非空口令） |
| 加速授权 | 冷启动弹出「开启 cfluxdo 加速」，选了「暂不」（授权会占用设备名额） |

新发现、未处理：书签列表里个别用户名显示成方框（字体缺字，Flatpak 里要核对字体回退）；WebView 里 CF 会悄悄换发新的 `cf_clearance`，jar 里还是旧的（旧的仍有效）。

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

## 3b. Windows（2026-10-16 起，分支 `desktop/windows`，基于 `desktop/linux`）

开发环境：VPS 上的 Windows 11 企业评估版 KVM 虚拟机（脚本在 `tool/windows_vm/`），出口可切到用户 Mac（国内网络）。

- **W1 恢复上游 Windows 代码**：`windows/` runner 与内置 `flutter_inappwebview_windows`（带 WebView2 销毁 UAF 修复）原样恢复后再改：改名 cfluxdo、数据目录 `%APPDATA%\com.github.molchuan\cfluxdo`、去掉构建期下载 ffmpeg、首帧后显示窗口。
- **W2 证书：WebView2 只信设备 CA，不进系统信任库**。上游把 CA 用 `certutil` 装进用户根信任库（对所有程序生效，还会弹系统确认框）。改为创建 WebView2 环境时加 `--ignore-certificate-errors-spki-list=<设备 CA 的 SPKI 摘要>`，只对 App 自己的 WebView2 生效；`requiresTrustedCa` 恒为 false。证书出错时仍按 Linux 的规则只认代理叶子（`ProxyLeafTrust`），不盲放行。
- **W3 桌面强制设备 CA**：内置 CA 的私钥随包分发、可被提取，不能当信任依据；Linux 一并改为强制。
- **W4 连接层**：与 Linux 相同，进程内 FFI、MITM 只限 `linux.do`、本地优选开启。
- **W5 毛玻璃**：上游 macOS/Windows 依赖 flutter_acrylic 把背景设透明，插件已删，透明处露出黑底；`PlatformUtils.hasWindowAcrylic` 统一关掉。

实测（国内出口）：
- **登录前**：游客列表正常；新出口 IP 下 CF 由后台 WebView2 自动通过。
- **证书**：WebView2 参数里的 SPKI 摘要与设备 CA 一致（openssl 核对）；经代理连 linux.do 收到的是设备 CA 签发的证书，github.com 收到的是真实证书；自签名坏证书被拒。
- **登录**：邮箱一次性代码登录，hCaptcha 由用户完成，登录后自动回到 App。
- **冷启动**：WebView2 自带 Cookie 持久化，不重过人机验证，登录保持。
- **`_t` 轮换**：轮换后 jar 更新，冷启动登录保持，没有出现两边不一致的告警。

已知：
- 冷启动核对 WebView2 Cookie 时报 `cf_clearance` / `_cfuvid` 缺失，实际存在，判断是 Windows 上核对通道的误报。
- 窗口大小和位置不记忆。
- 微软拼音默认中文模式。

构建要点：VS 2022 生成工具需加 ATL 组件；需要 `nuget.exe`；编译期 CA 用 Git 自带 openssl 生成（不要把 Git 的 `usr\bin` 加进 PATH，里面的 `link.exe` 会顶掉 MSVC 链接器）。

## 3c. Flatpak（2026-10-16，随 1.1.1-beta.4 发布）

- 清单 `flatpak/com.github.molchuan.cfluxdo.yml`，构建 `tool/flatpak_build.sh <输出>`：只打已提交的代码（git archive，含子模块），GNOME 48 运行时 + llvm20 扩展，WPE 用上游预编译层（WPE 2.48.7，带 WPEPlatform）。构建期借用宿主的 Flutter / pub 缓存 / Cargo / rustup（`--filesystem` + `--share=network`），所以只能在开发机上打，还不是可复现的离线构建。
- **和 chroot 的区别**：chroot 里的 WPE 没有 WPEPlatform，插件走 FDO；Flatpak 里走 WPEPlatform，渲染路径不同。WPEPlatform 路径有一个插件 bug：软件渲染下缓冲区留裸指针到下一帧，WebKit 重建交换链后变野指针，启动一两秒稳定 SIGSEGV。已修，见插件补丁 4（`packages/flutter_inappwebview_linux/CFLUXDO_PATCHES.md`）。
- 启动脚本在没有 `/dev/dri/renderD*` 时设 `LIBGL_ALWAYS_SOFTWARE=1`，否则无显卡环境窗口全黑。
- 实测（Xvfb + 软件渲染，VPS 直连出口）：游客列表、话题详情、Turnstile 勾选（`xdotool` 第二次点才过，和 chroot 一样）、冷启动不再弹盾（Cookie 落盘生效）、WebView 登录页正常显示。没有在 Flatpak 里重新登录。

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
