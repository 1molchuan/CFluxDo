# cfluxdo

> 面向国内网络环境的 [Linux.do](https://linux.do/) 第三方 Android 客户端，基于 [FluxDO](https://github.com/Lingyan000/fluxdo) 独立发行

[![GitHub Release](https://img.shields.io/github/v/release/1molchuan/fluxdo?style=for-the-badge&logo=github&label=GitHub%20Releases)](https://github.com/1molchuan/fluxdo/releases)
[![Platform](https://img.shields.io/badge/platform-Android%20arm64-3DDC84?style=for-the-badge&logo=android&logoColor=white)](https://github.com/1molchuan/fluxdo/releases)
[![License](https://img.shields.io/badge/license-GPL--3.0-blue?style=for-the-badge)](LICENSE)

cfluxdo 源自 FluxDO 0.2.28，已脱离 fork 关系独立维护。它保留了 FluxDO 的全部论坛功能与界面，重点解决国内网络下访问 linux.do 时遇到的 DNS 污染、频繁弹 Cloudflare 验证、无征兆掉登录等问题，并且只做 Android。

## 下载安装

- 到 [Releases](https://github.com/1molchuan/fluxdo/releases) 下载 `cfluxdo-<版本>-arm64-v8a.apk`，旁边有对应的 `.sha256` 校验文件。
- 只提供 arm64-v8a 一种架构，覆盖绝大多数 64 位 Android 手机。
- 包名是 `com.github.molchuan.cfluxdo`，与官方 FluxDO 不同：两者可以并存，但不能互相覆盖安装，登录态和设置也互不相通。
- 应用内「关于 → 检查更新」会从本仓库的 Releases 获取新版本。

## 与 FluxDO 的差异

- **cfluxdo 加速**：内置自建的 DoH 加速线路并作为默认 DNS。linux.do 及其子域按加速服务端下发的域名表与签名节点直接连接，不再依赖国内公共 DNS。加速线路不可用时自动回退到其他 DoH 服务器和系统 DNS，不会因此打不开 App。
- **弹盾与掉登录**：针对 Cloudflare 验证页、`cf_clearance` 与登录 Cookie `_t` 的轮换做了一系列修复，详见各版本的 Release 说明。
- **仅 Android**：移除了 iOS、桌面、Web 的平台代码，以及 Cronet 网络引擎和 Firebase 崩溃上报。崩溃排查依靠应用内的日志导出。安装包比同版本上游小约 11 MB。
- **上游补丁**：挑选上游尚未合并的 PR 一并接入，保留原作者署名。

## 隐私

- 发给 DoH 服务器的只有 DNS 查询本身，不附带 Cookie、令牌等任何账号信息。
- 没有崩溃上报、统计或任何遥测 SDK。
- 加速线路只负责 DNS 解析，论坛流量由手机直接连接 linux.do。

## 从源码构建

前置要求：

- Flutter 3.44（Dart SDK ^3.10.4）、Android SDK、NDK 27.3
- Rust 工具链、`cargo-ndk`、`aarch64-linux-android` target，用于编译 `core/doh_proxy`
- `just`（可选，仅作为本地命令入口）

```bash
git clone --recurse-submodules https://github.com/1molchuan/fluxdo.git
cd fluxdo
dart run melos bootstrap                 # 初始化 workspace
dart run tool/project_prep.dart app      # pub get、l10n 生成、代理证书同步，等价于 just sync
dart tool/flutterw.dart build apk --release --target-platform android-arm64 \
  --build-name 1.0.0 --build-number 2026101317
```

版本号约定：`--build-name` 是用户可见的版本号，`--build-number` 用「日期 + 两位序号」且只增不减。Git tag 与版本号一致，不带 `v` 前缀。

子模块：

- `core/doh_proxy`：Rust 实现的 DoH 代理与本地网关，来自 [1molchuan/fluxdo_doh](https://github.com/1molchuan/fluxdo_doh) 的 `cfluxdo` 分支
- `packages/fluxdo_render`：上游的渲染包

更多开发细节见 [docs/development.md](docs/development.md)。部分文档仍是上游多平台时期的内容，正在整理。

## 项目结构

```
fluxdo/
├── android/                 # Android 工程
├── lib/
│   ├── pages/               # 页面
│   ├── providers/           # Riverpod 状态管理
│   ├── services/            # 业务逻辑
│   │   └── network/         # 网络层：DoH、加速、本地网关、适配器
│   ├── widgets/             # 可复用组件
│   └── main.dart
├── core/
│   └── doh_proxy/           # Rust DoH 代理（子模块）
├── packages/                # 本地依赖包
└── pubspec.yaml
```

## 问题反馈

- 提交 [Issue](https://github.com/1molchuan/fluxdo/issues)
- 在 [Linux.do](https://linux.do/) 论坛发帖讨论

反馈掉登录、弹盾类问题时，请附上「应用设置 → 日志」导出的日志，里面不含密码和 Cookie 原文。

## 致谢与协议

cfluxdo 基于 [Lingyan000/fluxdo](https://github.com/Lingyan000/fluxdo)，感谢 FluxDO 的作者与所有贡献者，也感谢 [Linux.do](https://linux.do/) 社区。

本项目为非官方客户端，与 Linux.do 官方无直接关联。

本项目基于 [GPL-3.0](LICENSE) 协议开源。
