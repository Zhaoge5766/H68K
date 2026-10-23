#!/bin/bash
# =====================================================================
# DIY 第一步：feeds 还没下载时就执行
#
# 位置：官方源码 clone 完 + 适配层注入完 → 本脚本 → ./scripts/feeds update -a
#
# 做两件事：
#   1. 追加插件需要的第三方 feed（passwall2 / nikki）
#   2. 留几个"改源码字面量"的例子（默认注释掉）
# =====================================================================
set -euo pipefail

echo "== DIY-P1 =="

# ---------------------------------------------------------------- 1
# 插件 feed
#
#   openclash / diskman  → 官方 luci feed 里就有（luci-app-openclash、
#                          luci-app-diskman），不用加
#   passwall2            → Openwrt-Passwall 组织（原 xiaorouji/openwrt-passwall2，
#                          2026 年迁到组织名下，老地址已经 404）
#   nikki                → Mihomo 的 LuCI + mihomo 内核（mihomo 是虚拟包，
#                          实际由 mihomo-meta / mihomo-alpha 提供）
#
# ★ 为什么**不**加 openwrt-passwall-packages：
#   那个 feed 存在的意义是补 passwall 的依赖，但它 19 个包里 18 个与官方
#   packages feed 同名（xray-core / sing-box / chinadns-ng / geoview /
#   tcping / v2ray-geodata …）。同名 = 同 PKG_BUILD_DIR = 并行编译互相踩，
#   就是之前 aic8800 那个坑。而官方那份已经够新（geoview 两边都是 0.2.8，
#   xray-core / sing-box 跟着 master 走），所以只加"没有的那部分"。
#   唯一缺的是 shadowsocksr-libev（官方 feed 里没有），diy-part2.sh 会自动
#   把 passwall2 的 SSR 客户端开关关掉，免得 kconfig 里 select 一个不存在的包。
FEEDS=(
	"passwall2 https://github.com/Openwrt-Passwall/openwrt-passwall2.git;main"
	"nikki     https://github.com/nikkinikki-org/OpenWrt-nikki.git;main"
)

for entry in "${FEEDS[@]}"; do
	set -- $entry
	name=$1
	url=$2
	if grep -qE "^src-git[[:space:]]+${name}[[:space:]]" feeds.conf.default; then
		echo "   feed 已存在，跳过：$name"
	else
		echo "src-git ${name} ${url}" >> feeds.conf.default
		echo "   追加 feed：${name} -> ${url}"
	fi
done

echo "   当前 feed："
grep -E '^src-git' feeds.conf.default | sed 's/^/     /'

# ---------------------------------------------------------------- 2
# 下面这些是"改源码"的例子，默认注释掉 —— 保持能编出和上游一致的固件。

# ---- 例 1：再加别的第三方 feed ----
# cat >> feeds.conf.default <<'EOF'
# src-git kiddin9 https://github.com/kiddin9/kwrt-packages.git;main
# EOF

# ---- 例 2：改默认 LAN IP ----
# 注：HinLink 机型的默认网段由适配层的 board.d/03_hinlink-lan-ip 决定，
#     这里是**兜底**改法（对所有机型生效）。
# sed -i 's/192\.168\.1\.1/192.168.100.1/g' package/base-files/files/bin/config_generate

# ---- 例 3：改固件版本号后缀（LuCI 页面上显示的那串）----
# sed -i "s/^VERSION_NUMBER:=.*/VERSION_NUMBER:=h68k/" include/version.mk 2>/dev/null || true

echo "   DIY-P1 完成"
