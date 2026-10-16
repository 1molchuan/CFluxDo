#!/usr/bin/env bash
# flatpak-builder 沙箱里编译 cfluxdo Linux 版并装到 /app/cfluxdo
set -euo pipefail
export HOME="$PWD/.flatpak-home"
export XDG_CONFIG_HOME="$HOME/.config"
export CI=true
export PATH="$FLUTTER_ROOT/bin:$CARGO_HOME/bin:$PATH"
mkdir -p "$HOME"
git config --global --add safe.directory '*'

flutter config --no-analytics >/dev/null
dart tool/flutterw.dart build linux --release \
  --build-name="$BUILD_NAME" --build-number="$BUILD_NUMBER"

bundle=build/linux/x64/release/bundle
# 插件 CMake 会把 WPE 的库也拷进 bundle/lib；Flatpak 里统一用 /app/lib 那份（WPE 层），
# 留着两份既占空间又可能和 WPE 的辅助进程版本对不上
rm -f "$bundle"/lib/libWPEWebKit-* "$bundle"/lib/libWPEBackend-fdo-* "$bundle"/lib/libwpe-1.0.*
install -d /app/cfluxdo
cp -a "$bundle"/. /app/cfluxdo/
