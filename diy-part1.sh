#!/bin/bash
# =====================================================================
# DIY 第一步：feeds 还没下载时就执行
#
# 位置：官方源码 clone 完 + 适配层注入完 → 本脚本 → ./scripts/feeds update -a
#
# 适合放这类改动：
#   · 加第三方 feed（feeds.conf.default）
#   · 改默认 LAN IP / 主机名 / 固件版本号字面量（都是源码里的文件）
#   · 换主题、换默认语言
#
# 下面每条都写好了，但**默认注释掉** —— 保持"能编出和上游一致的固件"。
# 要用哪条就取消注释。
# =====================================================================
set -euo pipefail

echo "== DIY-P1 =="

# ---- 例 1：加第三方 feed（telecomix / kiddin9 之类的包源）----
# cat >> feeds.conf.default <<'EOF'
# src-git kiddin9 https://github.com/kiddin9/kwrt-packages.git;main
# EOF

# ---- 例 2：改默认 LAN IP ----
# 注：HinLink 机型的默认网段由适配层的 board.d/03_hinlink-lan-ip 决定，
#     这里是**兜底**改法（对所有机型生效）。
# sed -i 's/192\.168\.1\.1/192.168.100.1/g' package/base-files/files/bin/config_generate

# ---- 例 3：改固件版本号后缀（LuCI 页面上显示的那串）----
# sed -i "s/^VERSION_NUMBER:=.*/VERSION_NUMBER:=h68k/" include/version.mk 2>/dev/null || true

echo "   DIY-P1 完成（本步骤默认不改任何东西）"
