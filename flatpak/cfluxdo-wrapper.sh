#!/usr/bin/env bash
set -euo pipefail

export LD_LIBRARY_PATH="/app/cfluxdo/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"

# 应用已经在 Flatpak 沙箱里；WPE 层构建时也关了 bubblewrap，
# 再让 WebKit 给 WebProcess 套一层沙箱会直接起不来
export WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1

cd /app/cfluxdo
exec /app/cfluxdo/cfluxdo "$@"
