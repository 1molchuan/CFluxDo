#!/usr/bin/env bash
set -euo pipefail

export LD_LIBRARY_PATH="/app/cfluxdo/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"

# 应用已经在 Flatpak 沙箱里；WPE 层构建时也关了 bubblewrap，
# 再让 WebKit 给 WebProcess 套一层沙箱会直接起不来
export WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1

# 没有 GPU 渲染节点（无显卡的虚拟机、远程桌面）时走软件 GL，否则窗口全黑
if ! compgen -G '/dev/dri/renderD*' >/dev/null; then
  export LIBGL_ALWAYS_SOFTWARE=1
fi

cd /app/cfluxdo
exec /app/cfluxdo/cfluxdo "$@"
