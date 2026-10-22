#!/bin/bash
# =====================================================================
# DIY 第二步：feeds 装好之后，生成 .config 并 defconfig
#
# 位置：./scripts/feeds update -a && ./scripts/feeds install -a → 本脚本
#
# 它做四件事：
#   1. 删掉与本地包同名的 feed 软链（详见下方注释，这步不能省）
#   2. 用 configs/h68k.config 作种子
#   3. 按 $DEVICES 把机型符号打开
#   4. make defconfig，并校验机型数 / u-boot 变体
#
# 环境变量：
#   DEVICES    空格分隔的机型短名，默认 "h68k-new"
#   CONFIG_SEED 种子配置路径
# =====================================================================
set -euo pipefail

DEVICES="${DEVICES:-h68k-new}"
CONFIG_SEED="${CONFIG_SEED:-configs/h68k.config}"

echo "== DIY-P2 =="
echo "   机型：$DEVICES"
echo "   种子：$CONFIG_SEED"

# ---------------------------------------------------------------- 1
# feeds install -a 会在 package/feeds/<feed>/ 下建出与 package/beaverfffan/
# **同名**的包（fancontrol / luci-app-fancontrol / luci-app-oled）。
# OpenWrt 按字母序扫 package/：feeds > beaverfffan，同名包被 feed 那份
# **静默覆盖** —— 编译不报错，但装进固件的是上游版（温控默认关、OLED
# 界面拿 eth0 而不是 5G 的 wwan0）。所以必须删掉软链让本地版胜出。
echo "-- 清理与本地包同名的 feed 包"
if [ -d package/beaverfffan ]; then
	for d in package/beaverfffan/*/; do
		[ -d "$d" ] || continue
		name=$(basename "$d")
		find package/feeds -maxdepth 2 -name "$name" 2>/dev/null | while read -r p; do
			rm -rf "$p"
			echo "   删除冲突软链 $p"
		done
	done
fi

# ---------------------------------------------------------------- 2
[ -f "$CONFIG_SEED" ] || { echo "::error::找不到种子配置 $CONFIG_SEED"; exit 1; }
cp -f "$CONFIG_SEED" .config

# ---------------------------------------------------------------- 3
# 短名 -> device 名（即 image/armv8.mk 里 `define Device/hinlink_opc-xxx` 的后半段）
dev_symbol() {
	case "$1" in
		h68k-a-b)       echo hinlink_opc-h68k-a-b ;;
		h68k-a-b-usb)   echo hinlink_opc-h68k-a-b-usb ;;
		h68k-c-d-f)     echo hinlink_opc-h68k-c-d-f ;;
		h68k-c-d-f-usb) echo hinlink_opc-h68k-c-d-f-usb ;;
		h68k-new)       echo hinlink_opc-h68k-new ;;
		hinlink_*)      echo "$1" ;;          # 也允许直接写完整 device 名
		*)              echo "" ;;
	esac
}

want=0
for short in $DEVICES; do
	sym=$(dev_symbol "$short")
	if [ -z "$sym" ]; then
		echo "::error::不认识的机型 '$short'（可选：h68k-a-b h68k-a-b-usb h68k-c-d-f h68k-c-d-f-usb h68k-new，或完整的 hinlink_opc-xxx）"
		exit 1
	fi
	key="CONFIG_TARGET_DEVICE_rockchip_armv8_DEVICE_${sym}"
	# 种子里本来就有这一行（注释形态），直接改成 y
	sed -i "s|^# ${key} is not set|${key}=y|" .config
	grep -qx "${key}=y" .config || echo "${key}=y" >> .config
	want=$((want + 1))
	echo "   选中 $short -> $sym"
done

# 多机型时确保 MULTI_PROFILE（单机型留着也无害）
grep -q '^CONFIG_TARGET_MULTI_PROFILE=y' .config || echo 'CONFIG_TARGET_MULTI_PROFILE=y' >> .config

# ccache 目录固定到树内，跟 actions/cache 的路径对上
if grep -q '^CONFIG_CCACHE=y' .config; then
	sed -i "s|^CONFIG_CCACHE_DIR=.*|CONFIG_CCACHE_DIR=\"$PWD/.ccache\"|" .config
	grep -q '^CONFIG_CCACHE_DIR=' .config || echo "CONFIG_CCACHE_DIR=\"$PWD/.ccache\"" >> .config
fi

# ---------------------------------------------------------------- 4
echo "-- make defconfig"
make defconfig

echo
echo "-- 最终选中的机型"
grep -E '^CONFIG_TARGET_DEVICE_rockchip_armv8_DEVICE_hinlink.*=y$' .config || true

got=$(grep -cE '^CONFIG_TARGET_DEVICE_rockchip_armv8_DEVICE_hinlink.*=y$' .config || true)
if [ "$got" -ne "$want" ]; then
	echo "::error::期望 $want 个机型，实际 $got 个 —— 机型符号没被 kconfig 接受"
	echo "（通常是适配层没注入成功，或机型名改了）"
	exit 1
fi

if ! grep -qx 'CONFIG_PACKAGE_u-boot-hinlink-h68k-rk3568=y' .config; then
	echo "::error::u-boot 变体 hinlink-h68k-rk3568 没被选中，镜像阶段会缺 u-boot-rockchip.bin"
	exit 1
fi

echo "-- 校验通过：$got 个机型 + u-boot hinlink-h68k-rk3568"
