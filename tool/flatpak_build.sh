#!/usr/bin/env bash
# 打 cfluxdo 的 Flatpak 单文件包（x86_64）
# 用法: tool/flatpak_build.sh <输出 .flatpak 路径>
#       FLUTTER_ROOT=/root/sdk/flutter-3.47 指定 SDK；CFX_BUILD_NAME / CFX_BUILD_NUMBER 覆盖版本
# 依赖: flatpak、flatpak-builder、flathub 上的 org.gnome.Sdk//48 与 llvm20 扩展；
#       WPE 预编译层已解压到 $WPE_LAYER_DIR（上游 flatpak-wpe-layer-gnome48-v2 资产）
# 只打已提交的代码（git archive，含子模块），工作区里的改动不进包
set -euo pipefail

OUT=${1:?用法: tool/flatpak_build.sh <输出 .flatpak 路径>}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=${FLATPAK_WORK:-/srv/flatpak}
WPE_LAYER_DIR=${WPE_LAYER_DIR:-$WORK/wpe-layer}
FLUTTER_ROOT=${FLUTTER_ROOT:-$(dirname "$(dirname "$(readlink -f "$(command -v flutter)")")")}
# SDK 若是 git worktree（如 /root/sdk/flutter-3.47），它的 .git 指向主仓库的 .git，
# 沙箱里也要挂上，否则 flutter 读不到版本
FLUTTER_GIT_DIR=$(cd "$FLUTTER_ROOT" && readlink -f "$(git rev-parse --git-common-dir)")
PUB_CACHE=${PUB_CACHE:-$HOME/.pub-cache}
CARGO_HOME=${CARGO_HOME:-$HOME/.cargo}
RUSTUP_HOME=${RUSTUP_HOME:-$HOME/.rustup}

version=$(sed -n 's/^version: *//p' "$ROOT/pubspec.yaml")
# 测试包可用 CFX_BUILD_NAME / CFX_BUILD_NUMBER 覆盖 pubspec 里的版本
BUILD_NAME=${CFX_BUILD_NAME:-${version%%+*}}
BUILD_NUMBER=${CFX_BUILD_NUMBER:-${version##*+}}

# 1. 干净源码树
SRC=$WORK/stage/source-tree
rm -rf "$SRC" && mkdir -p "$SRC"
git -C "$ROOT" archive HEAD | tar -x -C "$SRC"
git -C "$ROOT" submodule foreach --quiet --recursive \
  "mkdir -p \"$SRC/\$sm_path\" && git archive HEAD | tar -x -C \"$SRC/\$sm_path\""
echo "==> 源码树 $(git -C "$ROOT" rev-parse --short HEAD) → $SRC（$BUILD_NAME+$BUILD_NUMBER）"

# 2. 填清单占位符
MANIFEST=$WORK/stage/com.github.molchuan.cfluxdo.yml
sed -e "s#@WPE_LAYER_DIR@#$WPE_LAYER_DIR#g" -e "s#@SOURCE_TREE@#$SRC#g" \
    -e "s#@FLUTTER_ROOT@#$FLUTTER_ROOT#g" -e "s#@FLUTTER_GIT_DIR@#$FLUTTER_GIT_DIR#g" \
    -e "s#@PUB_CACHE@#$PUB_CACHE#g" \
    -e "s#@CARGO_HOME@#$CARGO_HOME#g" -e "s#@RUSTUP_HOME@#$RUSTUP_HOME#g" \
    -e "s#@BUILD_NAME@#$BUILD_NAME#g" -e "s#@BUILD_NUMBER@#$BUILD_NUMBER#g" \
    "$ROOT/flatpak/com.github.molchuan.cfluxdo.yml" > "$MANIFEST"

# 3. 构建并导出
flatpak-builder --force-clean --disable-rofiles-fuse --state-dir="$WORK/.flatpak-builder" \
  --repo="$WORK/repo" "$WORK/build-dir" "$MANIFEST"
flatpak build-bundle --runtime-repo=https://dl.flathub.org/repo/flathub.flatpakrepo \
  "$WORK/repo" "$OUT" com.github.molchuan.cfluxdo
ls -la "$OUT"
