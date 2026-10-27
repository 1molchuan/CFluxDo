# CFluxDo

> 面向国内网络环境的 [Linux.do](https://linux.do/) 第三方 Android 客户端（另有 Windows / Linux 桌面预览版），基于 [FluxDO](https://github.com/Lingyan000/fluxdo) 独立发行

[![GitHub Release](https://img.shields.io/github/v/release/1molchuan/CFluxDo?style=for-the-badge&logo=github&label=GitHub%20Releases)](https://github.com/1molchuan/CFluxDo/releases)
[![Platform](https://img.shields.io/badge/platform-Android%20arm64%20%7C%20armv7%20%7C%20Windows%20%7C%20Linux-3DDC84?style=for-the-badge&logo=android&logoColor=white)](https://github.com/1molchuan/CFluxDo/releases)
[![License](https://img.shields.io/badge/license-GPL--3.0-blue?style=for-the-badge)](LICENSE)

CFluxDo 源自 FluxDO 0.2.28，已脱离 fork 关系独立维护，并持续同步上游（目前到 v0.2.29）。它保留了 FluxDO 的全部论坛功能，重点解决国内网络下访问 linux.do 时遇到的 DNS 污染、频繁弹 Cloudflare 验证、无征兆掉登录等问题。以 Android 为主，Windows、Linux 桌面端为预览版。

## 下载安装

- 到 [Releases](https://github.com/1molchuan/CFluxDo/releases) 下载对应平台和架构的安装包，旁边有同名的 `.sha256` 校验文件：
  - `cfluxdo-<版本>-arm64-v8a.apk`：64 位 ARM，2015 年以后的手机几乎都是，优先选这个。
  - `cfluxdo-<版本>-armeabi-v7a.apk`：32 位 ARM，只给装不上 arm64 包（报 `INSTALL_FAILED_NO_MATCHING_ABIS`）的老机器。
  - `cfluxdo-<版本>-windows-x86_64.zip`：Windows 10/11 64 位桌面预览版，解压后运行 `cfluxdo.exe`，需要 WebView2 运行时（Windows 11 自带）。没有代码签名，第一次运行如果出现「Windows 已保护你的电脑」，点「更多信息 → 仍要运行」。
  - `cfluxdo-<版本>-linux-x86_64.flatpak`：Linux 桌面预览版，`flatpak install --user <文件名>` 安装，第一次会从 Flathub 下载 GNOME 运行时。
- 包名是 `com.github.molchuan.cfluxdo`，与官方 FluxDO 不同：两者可以并存，但不能互相覆盖安装，登录态和设置也互不相通。
- 应用内「关于 → 检查更新」会从本仓库的 Releases 获取正式版：Android 按手机架构挑选安装包在应用内下载；桌面版只提示并打开下载页面。

## 它怎么连接 linux.do

从 1.1.0 起，CFluxDo 默认不依赖任何中转服务，由 App 自己在 Cloudflare 共享池里找能连上 linux.do 的节点：

1. **取候选**：向公共 DNS（DNSPod、AliDNS、360、Cloudflare、Google、Quad9 等，直连 IP、并发竞速）查询若干托管在 Cloudflare 上的大厂站点，加上社区维护的节点表 atlas，再从 Cloudflare 公布的网段随机抽样。答案不在 Cloudflare 网段内的一律丢弃，防 DNS 投毒。公共 DNS 从不查询 `linux.do` 本身。
2. **竞速**：对候选并发做 ECH 加密握手（内层 SNI 为 linux.do，明文 SNI 在国内会被重置）并请求 `/cdn-cgi/trace`，响应里 `h=linux.do` 才算通过，最快的记为赢家并落盘。
3. **使用**：之后 linux.do 及其所有子域都走赢家这一个节点、同一个地址族，保证 Cloudflare 看到的出口 IP 不变。Cloudflare 换 ECH 钥匙时，用服务端返回的 retry_configs 当场换钥匙重试，不等 DNS 刷新。
4. **重测时机**：切换网络、赢家连续失败、或在设置里手动点「重新优选」。没有定时重测，也没有后台任务。单次竞速约 50–200 KB 流量。

「设置 → 网络 → 连接方式」可以改为「只用 atlas 池」。两种方式都拿不到候选时，自动回退到原有的 DoH 加速线路，仍然连不上则回退系统 DNS，不会因此打不开 App。

## 与 FluxDO 的差异

- **连接方式**：上面的本地优选替代了对加速服务端的依赖；原有的 DoH 加速线路降为兜底。
- **弹盾与掉登录**：针对 Cloudflare 验证页、`cf_clearance` 与登录 Cookie `_t` 的轮换做了一系列修复，详见各版本的 Release 说明。
- **界面**：默认「墨笺」阅读风格（纸色底、宋体标题、细线分隔）；原来的界面保留为「经典」，在「我的 → 应用设置 → 外观 → 界面风格」切换。
- **平台**：以 Android 为主；Windows、Linux 桌面端为预览版，和 Android 共用同一套连接层，视频楼层播放等功能还不完整。移除了 iOS、macOS、Web 的平台代码，以及 Cronet 网络引擎和 Firebase 崩溃上报，崩溃排查依靠应用内的日志导出。
- **上游补丁**：挑选上游尚未合并的 PR 一并接入，保留原作者署名。

## 隐私

- 本地优选向公共 DNS 发出的只是域名查询本身，不附带 Cookie、令牌等任何账号信息，也不查询 `linux.do`。
- **「帮助优选」默认关闭**。打开后 App 会把本来就做的握手测量结果（候选节点地址、握手耗时、是否成功）分享给社区节点站 [cfhub](https://github.com/1molchuan/cfhub)，帮同运营商的其他用户更快找到节点。开启需要用 linux.do 账号通过 Connect 授权 cfhub（与在 cfhub 网页上加入相同，需信任等级 1 以上）；分享内容不含 Cookie、令牌、设备标识或浏览记录；cfhub 记录你的 linux.do 用户名、信任等级和上报归属的运营商与地区，不保存你的完整 IP 地址；随时可关，关闭即作废授权。
- 首次启动 1.1 会弹一次说明，列出以上内容。
- 没有崩溃上报、统计或任何遥测 SDK。论坛流量由手机直接连接 linux.do。

## 从源码构建

前置要求：

- Flutter 3.47（Dart SDK ^3.13）、Android SDK、NDK 27.3
- Rust 工具链、`cargo-ndk`，以及 `aarch64-linux-android`、`armv7-linux-androideabi` 两个 target，用于编译 `core/doh_proxy`
- `just`（可选，仅作为本地命令入口）

```bash
git clone --recurse-submodules https://github.com/1molchuan/CFluxDo.git
cd CFluxDo
dart run melos bootstrap                 # 初始化 workspace
dart run tool/project_prep.dart app      # pub get、l10n 生成、代理证书同步，等价于 just sync
dart tool/flutterw.dart build apk --release --target-platform android-arm64 \
  --build-name 1.2.1 --build-number 2026102408
dart tool/flutterw.dart build apk --release --target-platform android-arm \
  --build-name 1.2.1 --build-number 2026102408
```

`flutterw` 会在构建前用 `cargo ndk` 编译对应架构的 Rust 库并放进 `android/app/src/main/jniLibs/`。两个架构各出一个 APK，不出合并包。

桌面预览版：Linux 用 `tool/flatpak_build.sh <输出.flatpak>` 打 Flatpak 包（设计说明见 [docs/desktop/linux-design.md](docs/desktop/linux-design.md)）；Windows 在 Windows 上用 `dart tool/flutterw.dart build windows --release` 构建，开发虚拟机脚本在 `tool/windows_vm/`。

版本号约定：`--build-name` 是用户可见的版本号，`--build-number` 用「日期 + 两位序号」且只增不减。Git tag 与版本号一致，不带 `v` 前缀。预发布版本带 `-beta` 一类后缀，GitHub Release 标为 Pre-release；App 内的更新检查只看正式版（Latest），不会推送预发布版本。

子模块：

- `core/doh_proxy`：Rust 实现的本地优选、ECH、DoH 代理与本地网关，来自 [1molchuan/fluxdo_doh](https://github.com/1molchuan/fluxdo_doh) 的 `cfluxdo` 分支。`cargo run --example race --features ech` 可以在电脑上跑一轮竞速看结果。
- `packages/fluxdo_render`：帖子渲染包，来自 [1molchuan/fluxdo_render](https://github.com/1molchuan/fluxdo_render) 的 `cfluxdo` 分支（上游渲染包的 fork）

更多开发细节见 [docs/development.md](docs/development.md)。部分文档仍是上游多平台时期的内容，正在整理。

## 项目结构

```
CFluxDo/
├── android/                 # Android 工程
├── lib/
│   ├── pages/               # 页面
│   ├── providers/           # Riverpod 状态管理
│   ├── services/            # 业务逻辑
│   │   └── network/         # 网络层：本地优选、DoH、本地网关、适配器
│   ├── widgets/             # 可复用组件
│   └── main.dart
├── core/
│   └── doh_proxy/           # Rust 本地优选与 DoH 代理（子模块）
├── packages/                # 本地依赖包
└── pubspec.yaml
```

## 问题反馈

- 提交 [Issue](https://github.com/1molchuan/CFluxDo/issues)
- 在 [Linux.do](https://linux.do/) 论坛发帖讨论

反馈掉登录、弹盾类问题时，请附上「应用设置 → 日志」导出的日志，里面不含密码和 Cookie 原文。反复弹人机验证多半是出口 IP 在变：手机上开着多节点或自动切换的 VPN、ROM 的「双通道网络加速」都会造成这种情况，先关掉再试。

## 致谢与协议

CFluxDo 基于 [Lingyan000/fluxdo](https://github.com/Lingyan000/fluxdo)，感谢 FluxDO 的作者与所有贡献者，也感谢 [Linux.do](https://linux.do/) 社区。

本项目为非官方客户端，与 Linux.do 官方无直接关联。

本项目基于 [GPL-3.0](LICENSE) 协议开源。
