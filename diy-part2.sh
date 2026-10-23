#!/bin/bash
# =====================================================================
# DIY 第二步：feeds 装好之后，生成 .config 并 defconfig
#
# 位置：./scripts/feeds update -a && ./scripts/feeds install -a → 本脚本
#
# 它做六件事：
#   1. 删掉与本地包同名的 feed 软链（详见下方注释，这步不能省）
#   2. 用 configs/h68k.config 作种子
#   3. 按 $DEVICES 把机型符号打开
#   4. 按 $PLUGINS 把插件包打开（含依赖校验）
#   5. make defconfig，并校验机型数 / u-boot 变体 / 插件是否真被接受
#   6. 预检机型自带的 DEVICE_PACKAGES 是否存在（不然要等镜像阶段才炸）
#
# 环境变量：
#   DEVICES      空格分隔的机型短名，默认全系 5 个
#   PLUGINS      空格分隔的插件短名，默认 passwall2 nikki openclash diskman
#                （给空串 = 一个插件都不加）
#   CONFIG_SEED  种子配置路径
# =====================================================================
set -euo pipefail

DEVICES="${DEVICES-h68k-a-b h68k-a-b-usb h68k-c-d-f h68k-c-d-f-usb h68k-new}"
PLUGINS="${PLUGINS-passwall2 nikki openclash diskman}"
# 给 none / off 就是"一个都不加"，省得为了"不加插件"去记一个空串怎么填
case "$PLUGINS" in none|no|off|-) PLUGINS="" ;; esac
CONFIG_SEED="${CONFIG_SEED:-configs/h68k.config}"

[ -n "$DEVICES" ] || { echo "::error::DEVICES 是空的，一个机型都没选中"; exit 1; }

echo "== DIY-P2 =="
echo "   机型：$DEVICES"
echo "   插件：${PLUGINS:-（无）}"
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
SEL_SYMS=""
for short in $DEVICES; do
	sym=$(dev_symbol "$short")
	if [ -z "$sym" ]; then
		echo "::error::不认识的机型 '$short'（可选：h68k-a-b h68k-a-b-usb h68k-c-d-f h68k-c-d-f-usb h68k-new，或完整的 hinlink_opc-xxx）"
		exit 1
	fi
	key="CONFIG_TARGET_DEVICE_rockchip_armv8_DEVICE_${sym}"
	# 机型必须先出现在 armv8.mk 的 TARGET_DEVICES 里，否则 kconfig 压根看不见
	# 这个符号，defconfig 会把我们写进去的那行当未知符号丢掉（症状：defconfig
	# 不报错，但一个机型都没选中）。这里提前一步拦下来。
	if ! grep -qE "^TARGET_DEVICES \+=.*\b${sym}\b" target/linux/rockchip/image/armv8.mk; then
		echo "::error::$sym 没有 TARGET_DEVICES 注册（适配层注入不完整）"
		exit 1
	fi
	sed -i "/^${key}=/d;/^# ${key}[= ]/d" .config
	echo "${key}=y" >> .config
	want=$((want + 1))
	SEL_SYMS="$SEL_SYMS $sym"
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
# 插件短名 -> 需要打开的 CONFIG_PACKAGE_* 列表
#
#   nikki 那三个都要写：luci-app-nikki 是界面，nikki 是后端脚本，mihomo-meta
#   是内核。链路上 nikki 只写 `+mihomo`，而 mihomo 是**虚拟包**（由
#   mihomo-meta / mihomo-alpha 提供，两者 CONFLICTS），虚拟包不能被 =y，
#   必须显式选一个真实提供者，否则 nikki 的依赖判定失败、包会被静默丢掉。
plugin_pkgs() {
	case "$1" in
		passwall2) echo "luci-app-passwall2" ;;
		nikki)     echo "luci-app-nikki nikki mihomo-meta" ;;
		openclash) echo "luci-app-openclash" ;;
		diskman)   echo "luci-app-diskman" ;;
		*)         echo "" ;;
	esac
}

# 包是否真的装进了树里。三种位置都要看：
#   package/feeds/<feed>/<name>  feed 包
#   package/<group>/<name>       核心包，如 package/utils/e2fsprogs
#   package/<name>               核心包，如 package/base-files
# ⚠️ 不能只写 package/*/<name> —— 那会把 package/feeds/<name> 这个**feed 目录**
#    本身当成包（feed 名和包名撞的时候，比如 feed 叫 nikki、包也叫 nikki），
#    结果是"包明明没装上却检查通过"。
pkg_dir() {
	for d in package/feeds/*/"$1" package/*/*/"$1" package/"$1"; do
		if [ -d "$d" ]; then
			echo "$d"
			return 0
		fi
	done
	return 1
}

echo "-- 打开插件"
wanted_pkgs=""
for plug in $PLUGINS; do
	pkgs=$(plugin_pkgs "$plug")
	if [ -z "$pkgs" ]; then
		echo "::error::不认识的插件 '$plug'（可选：passwall2 nikki openclash diskman）"
		exit 1
	fi
	for p in $pkgs; do
		if ! d=$(pkg_dir "$p"); then
			echo "::error::树里找不到包 $p（插件 $plug 需要它）"
			echo "  可能原因：diy-part1.sh 里没加对应的 feed，或 feed 名写错"
			exit 1
		fi
		sed -i "/^CONFIG_PACKAGE_${p}=/d;/^# CONFIG_PACKAGE_${p}[= ]/d" .config
		echo "CONFIG_PACKAGE_${p}=y" >> .config
		wanted_pkgs="$wanted_pkgs $p"
		echo "   插件 $plug -> $p  ($d)"
	done
done
wanted_pkgs="${wanted_pkgs# }"

# passwall2 的 SSR 客户端开关 `default y` 会 select shadowsocksr-libev-ssr-*，
# 而官方 feed 里没有 shadowsocksr-libev（只有 openwrt-passwall-packages 有，
# 那个 feed 不能加，见 diy-part1.sh）。select 一个不存在的符号会让 kconfig
# 报怪问题，干脆显式关掉 —— 少一个 SSR 协议，其余照旧。
case " $PLUGINS " in
	*" passwall2 "*)
		if ! pkg_dir shadowsocksr-libev >/dev/null; then
			key='CONFIG_PACKAGE_luci-app-passwall2_INCLUDE_ShadowsocksR_Libev_Client'
			sed -i "/^${key}=/d;/^# ${key}[= ]/d" .config
			echo "# ${key} is not set" >> .config
			echo "   passwall2：feed 里没有 shadowsocksr-libev，关掉 SSR 客户端支持"
		fi
		;;
esac

# ---------------------------------------------------------------- 5
echo "-- make defconfig"
make defconfig

echo
echo "-- 最终选中的机型"
grep -E '^CONFIG_TARGET_DEVICE_rockchip_armv8_DEVICE_hinlink.*=y$' .config || true

got=$(grep -cE '^CONFIG_TARGET_DEVICE_rockchip_armv8_DEVICE_hinlink.*=y$' .config || true)
if [ "$got" -ne "$want" ]; then
	echo "::error::期望 $want 个机型，实际 $got 个 —— 机型符号没被 kconfig 接受"
	echo "（通常是适配层没注入成功，或机型名改了）"
	echo "--- .config 里的 target 相关行 ---"
	grep -E '^CONFIG_TARGET_rockchip|^# CONFIG_TARGET_rockchip|^CONFIG_TARGET_MULTI_PROFILE' .config | head -10 || true
	echo "--- .config 里 device 符号计数 ---"
	grep -cE '^CONFIG_TARGET_DEVICE_' .config || true
	echo "--- armv8.mk 里的注册行 ---"
	grep -cE '^TARGET_DEVICES \+= hinlink' target/linux/rockchip/image/armv8.mk || true
	exit 1
fi

if ! grep -qx 'CONFIG_PACKAGE_u-boot-hinlink-h68k-rk3568=y' .config; then
	echo "::error::u-boot 变体 hinlink-h68k-rk3568 没被选中，镜像阶段会缺 u-boot-rockchip.bin"
	exit 1
fi

# dnsmasq 两条并存 = 镜像阶段文件冲突（/usr/sbin/dnsmasq 装两次）。
# 机型是 DEVICE_TYPE=router，默认包集里本来就是 dnsmasq-full，正常不会撞；
# 撞了说明有包把 plain dnsmasq 拉进来了，留 dnsmasq-full（openclash /
# passwall2 都依赖它的 ipset / nftset 能力）。
if grep -qx 'CONFIG_PACKAGE_dnsmasq=y' .config && grep -qx 'CONFIG_PACKAGE_dnsmasq-full=y' .config; then
	echo "::warning::dnsmasq 与 dnsmasq-full 同时选中，关掉 plain dnsmasq"
	sed -i 's|^CONFIG_PACKAGE_dnsmasq=y|# CONFIG_PACKAGE_dnsmasq is not set|' .config
fi

# 插件校验：defconfig 对"依赖不满足"的包是**静默丢弃**（不报错，只是变成
# "# ... is not set"），所以必须回头确认一遍。
missing=""
for p in $wanted_pkgs; do
	grep -qx "CONFIG_PACKAGE_${p}=y" .config || missing="$missing $p"
done
if [ -n "$missing" ]; then
	echo "::error::这些包没被 kconfig 接受：${missing# }"
	for p in $missing; do
		echo "--- $p ---"
		if grep -qx "config PACKAGE_${p}" tmp/.config-package.in 2>/dev/null; then
			echo "符号存在 ⇒ 依赖没满足，它的依赖条件："
			awk -v s="config PACKAGE_${p}" '
				$0 == s { f = 1 }
				f && /depends on/ { print "   " $0 }
				f && /^(config|menuconfig) / && $0 != s { exit }
			' tmp/.config-package.in | head -10
		else
			echo "tmp/.config-package.in 里没有这个符号 ⇒ 包根本没被 feeds 装进来"
			ls -d package/feeds/*/"$p" 2>/dev/null || echo "   （package/feeds/*/$p 不存在）"
		fi
	done
	exit 1
fi

echo
echo "-- 插件已全部落到 .config"
for p in $wanted_pkgs; do echo "   $p"; done

# rootfs 分区够不够大
#   ext4 根镜像按 CONFIG_TARGET_ROOTFS_PARTSIZE 定长做（make_ext4fs -l N M），
#   默认 160 MiB。装了几个代理插件之后未压缩 rootfs 轻松超 200 MiB，
#   镜像阶段就会在**第一台机器**上报 Not enough space 而整体失败 —— 而且
#   这个错在 BUILD_LOG 没开时是抓不到的，只能白跑几小时。
rfs=$(sed -n 's/^CONFIG_TARGET_ROOTFS_PARTSIZE=//p' .config | tr -d '"')
rfs=${rfs:-160}
echo "   rootfs 分区：${rfs} MiB"
if [ -n "$PLUGINS" ] && [ "$rfs" -lt 512 ] 2>/dev/null; then
	echo "::error::rootfs 分区只有 ${rfs} MiB —— 装了 ${PLUGINS} 之后 ext4 根镜像会超限"
	echo "（改 configs/h68k.config 里的 CONFIG_TARGET_ROOTFS_PARTSIZE，建议 1024）"
	exit 1
fi

# ---------------------------------------------------------------- 6
# 机型自带包（DEVICE_PACKAGES）预检
#
# 这一步是防"编译 2.5 小时后在 target/linux install 阶段炸掉、且一行报错都
# 看不到"的：机型的 DEVICE_PACKAGES 里只要有一个包名在树里不存在，
# `make defconfig` 会**静默丢弃**那个符号（不报错），包就不会被编；
# 到镜像阶段 opkg 才报 "Cannot install package xxx"，而那行输出在
# BUILD_LOG 没开的时候是拿不到的。
#
# 判据分两档：
#   · tmp/.config-package.in 里连符号都没有  → 包名根本不存在，100% 会炸 ⇒ 直接 fail
#   · 符号在但没被选上（=y/m 都没有）        → 可能是被 Provides 的虚拟包，
#                                              只警告，交给镜像阶段判定
echo "-- 机型自带包预检"
if [ -f tmp/.targetinfo ]; then
	for sym in $SEL_SYMS; do
		# .targetinfo 里的 profile 键有的版本带 DEVICE_ 前缀，两种都认
		pkgs=$(awk -v a="DEVICE_${sym}" -v b="${sym}" '
			/^Target-Profile:/ {
				v = $0
				sub(/^Target-Profile:[ \t]*/, "", v)
				f = (v == a || v == b)
				next
			}
			f && /^Target-Profile-Packages:/ {
				sub(/^Target-Profile-Packages:[ \t]*/, ""); print; exit
			}
			f && /^Target-Profile-/ { exit }
		' tmp/.targetinfo)
		if [ -z "$pkgs" ]; then
			echo "::warning::tmp/.targetinfo 里没找到 ${sym} 的包列表，跳过预检"
			continue
		fi
		nope=""
		off=""
		for p in $pkgs; do
			case "$p" in -*) continue ;; esac       # 前缀 - 表示从默认包集里去掉
			if ! grep -qx "config PACKAGE_${p}" tmp/.config-package.in 2>/dev/null; then
				nope="$nope $p"
			elif ! grep -qE "^CONFIG_PACKAGE_${p}=[ym]\$" .config; then
				off="$off $p"
			fi
		done
		printf '   %-24s 共 %s 个包\n' "${sym#hinlink_opc-}" "$(echo "$pkgs" | wc -w)"
		if [ -n "$nope" ]; then
			echo "::error::${sym} 的 DEVICE_PACKAGES 里有树里不存在的包：${nope# }"
			echo "  （这些包名写错了或者上游删了，镜像阶段一定会失败）"
			exit 1
		fi
		if [ -n "$off" ]; then
			echo "::warning::${sym} 这些包没被选中（可能被 Provides 顶替）：${off# }"
		fi
	done
else
	echo "::warning::没有 tmp/.targetinfo，跳过机型包预检"
fi

set -- $wanted_pkgs
echo "-- 校验通过：$got 个机型 + u-boot hinlink-h68k-rk3568 + $# 个插件包"
