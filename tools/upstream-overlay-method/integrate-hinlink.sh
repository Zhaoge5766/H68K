#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 把 Beaverfffan/immortalwrt-hinlink 适配层合入 immortalwrt 源码树
# 目标机型：HinLink H68K（RK3568 / rockchip-armv8）
#
# 用法：
#   ./integrate-hinlink.sh <immortalwrt 目录> <immortalwrt-hinlink 目录>
#
# 可选环境变量：
#   APPLY_KERNEL_PATCHES=1
#      合入适配层 patches/*.patch（fbcon 光标 / fbtft gc9307 / fbtft 偏移，
#      都是给 H29K、H89K 的屏用的，H68K 没有屏，默认不合，减小风险）
#   APPLY_TARGET_CONFIG=1
#      把 hinlink-config.append 追加进 armv8/config-6.18（同上，默认不合）
#   UBOOT_UPSTREAM_PATCHES="106"
#      合入 patches-uboot/upstream/ 下的哪些补丁（H68K 只需要 106）
#   LOCAL_PKG_EXCLUDE="fancontrol luci-app-fancontrol"
#      不复制到 package/beaverfffan 的本地包目录。
#      这两个包名与官方 feed 里的同名包冲突（适配层里是"换默认配置"的副本），
#      只编 H68K 时用不到，默认排除。要编 H69K/H88K/H89K 时设成空串。
# ---------------------------------------------------------------------------
set -euo pipefail

IWRT_DIR="${1:?用法: integrate-hinlink.sh <immortalwrt 目录> <hinlink 目录>}"
OVERLAY_DIR="${2:?用法: integrate-hinlink.sh <immortalwrt 目录> <hinlink 目录>}"

APPLY_KERNEL_PATCHES="${APPLY_KERNEL_PATCHES:-0}"
APPLY_TARGET_CONFIG="${APPLY_TARGET_CONFIG:-0}"
UBOOT_UPSTREAM_PATCHES="${UBOOT_UPSTREAM_PATCHES:-106}"
LOCAL_PKG_EXCLUDE="${LOCAL_PKG_EXCLUDE-fancontrol luci-app-fancontrol}"

log()  { printf '\n\033[1;36m[hinlink]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[hinlink][warn]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[hinlink][error]\033[0m %s\n' "$*" >&2; exit 1; }

[ -d "$IWRT_DIR/target/linux/rockchip" ] || die "不是 immortalwrt 源码树: $IWRT_DIR"
[ -d "$OVERLAY_DIR/target/linux/rockchip" ] || die "不是 immortalwrt-hinlink 仓库: $OVERLAY_DIR"

IWRT_ROCK="$IWRT_DIR/target/linux/rockchip"
OVL_ROCK="$OVERLAY_DIR/target/linux/rockchip"
DTS_DST="$IWRT_ROCK/files/arch/arm64/boot/dts/rockchip"
BOARDD_DST="$IWRT_ROCK/armv8/base-files/etc/board.d"

mkdir -p "$DTS_DST" "$BOARDD_DST"

# ---------------------------------------------------------------------------
# 1) 设备树：全部 rk*.dts / rk*.dtsi（含公共 dtsi，机型 dts 依赖它们）
#    排除 vendor-*.dtb（厂商 dtb 只是参照物，不能进内核树）
# ---------------------------------------------------------------------------
log "[1/7] 拷贝设备树"
dts_count=0
for f in "$OVL_ROCK/files/arch/arm64/boot/dts/rockchip"/rk*.dts*; do
	[ -f "$f" ] || continue
	cp -f "$f" "$DTS_DST/"
	dts_count=$((dts_count + 1))
done
[ "$dts_count" -gt 0 ] || die "适配层里没找到任何 rk*.dts*"
echo "    已拷贝 $dts_count 个 dts/dtsi -> $DTS_DST"

# ---------------------------------------------------------------------------
# 2) 机型定义（armv8.mk.hinlink）
#
#    注意：这里用"把内容追加进 armv8.mk"而不是适配层 integrate.py 的
#    `include ./armv8.mk.hinlink`。OpenWrt 的 image/Makefile 是从 toplevel
#    里 include 的，make 的 include 路径相对**当前工作目录**而不是相对
#    makefile 所在目录，`include ./xxx` 会依赖调用方式；直接追加最稳。
# ---------------------------------------------------------------------------
log "[2/7] 合入机型定义"

SRC_MK="$OVL_ROCK/image/armv8.mk.hinlink"
DST_MK="$IWRT_ROCK/image/armv8.mk.hinlink"
[ -f "$SRC_MK" ] || die "缺少 image/armv8.mk.hinlink"

# 只保留 H68K 机型 + 它们依赖的公共 define。
# DEVICES=all 表示不裁剪、原样合入全系机型（注意 H29K 机型名带小数点，
# 会把 kconfig 符号弄成非法语法，见 scripts/filter-devices.py 的说明）。
DEVICES="${DEVICES:-hinlink_opc-h68k-a-b hinlink_opc-h68k-a-b-usb hinlink_opc-h68k-c-d-f hinlink_opc-h68k-c-d-f-usb hinlink_opc-h68k-new}"
DEVICE_HELPERS="hinlink_common hinlink_fan hinlink_modem \
hinlink_h6xk_base hinlink_h6xk_m2_wifi hinlink_h6xk_sdio_aic8800 hinlink_h6xk_sdio_ap6256"

if [ "$DEVICES" = "all" ]; then
	cp -f "$SRC_MK" "$DST_MK"
	echo "    未裁剪，原样拷贝 $(grep -c 'define Device/' "$DST_MK") 个机型定义"
else
	# shellcheck disable=SC2086
	python3 "$(dirname "$0")/filter-devices.py" "$SRC_MK" "$DST_MK" \
		$DEVICE_HELPERS $DEVICES
fi

MK="$IWRT_ROCK/image/armv8.mk"
MARK="# ===== HinLink 机型适配层（自动合入，勿手改）====="
# 幂等：重复执行时先把上一次追加的内容切掉
if grep -qF "$MARK" "$MK"; then
	awk -v m="$MARK" 'index($0, m) {exit} {print}' "$MK" > "$MK.tmp" && mv "$MK.tmp" "$MK"
fi
{
	printf '\n%s\n' "$MARK"
	cat "$DST_MK"
} >> "$MK"
echo "    已把机型定义追加进 armv8.mk"

# ---------------------------------------------------------------------------
# 3) 板级脚本：以**独立 board.d 文件**放入，而不是插进官方 01_leds/02_network
#
#    原因：官方 01_leds / 02_network 的 case 块数量会随版本变，插 case 块
#    的脚本一旦对不上就静默跳过（适配层自己的 integrate.py 就要求"块数相等"，
#    对不上直接 skip）。而这两个文件本身就自带 board_config_update / flush /
#    exit 0，是完整可执行脚本 —— 直接当独立脚本落地，按文件名顺序排在官方
#    02_network 之后执行，官方对未知 board 的兜底是空操作，互不干扰。
#
#    顺序：01_leds → 02_network → 03_hinlink_leds → 04_hinlink_network
#          → 05_hinlink_lan_ip   （ls 的字典序保证）
# ---------------------------------------------------------------------------
log "[3/7] 安装板级脚本"
install -m 0755 "$OVL_ROCK/armv8/base-files/etc/board.d/01_leds" \
	"$BOARDD_DST/03_hinlink_leds"
install -m 0755 "$OVL_ROCK/armv8/base-files/etc/board.d/02_network" \
	"$BOARDD_DST/04_hinlink_network"
install -m 0755 "$OVL_ROCK/armv8/base-files/etc/board.d/03_hinlink-lan-ip" \
	"$BOARDD_DST/05_hinlink_lan_ip"
echo "    03_hinlink_leds / 04_hinlink_network / 05_hinlink_lan_ip"

# ---------------------------------------------------------------------------
# 4) 内核补丁（可选）
# ---------------------------------------------------------------------------
log "[4/7] 内核补丁"
PATCH_DIR="$(ls -d "$IWRT_ROCK"/patches-[0-9]* 2>/dev/null | sort -V | tail -1 || true)"
if [ "$APPLY_KERNEL_PATCHES" = "1" ] && [ -n "$PATCH_DIR" ]; then
	for p in "$OVERLAY_DIR"/patches/*.patch; do
		[ -f "$p" ] || continue
		cp -f "$p" "$PATCH_DIR/"
		echo "    + $(basename "$p") -> $(basename "$PATCH_DIR")"
	done
	warn "内核补丁只在编译阶段才会真正校验能否打上；打不上会直接编译失败。"
	warn "H68K 没有屏，用不到这些补丁，建议保持 APPLY_KERNEL_PATCHES=0。"
else
	echo "    跳过（APPLY_KERNEL_PATCHES=$APPLY_KERNEL_PATCHES，H68K 无需屏驱动补丁）"
fi

# ---------------------------------------------------------------------------
# 5) U-Boot
#
#    u-boot 2026.10 的 dts/upstream 里已经有 rk3568-hinlink-h68k.dts，
#    但 configs/hinlink-h68k-rk3568_defconfig 没有 —— 需要上游补丁 106
#    （纯新增文件：arch/arm/dts/*-u-boot.dtsi + configs/*_defconfig）。
#    另外 uboot-rockchip/Makefile 里必须注册 U-Boot/hinlink-h68k-rk3568，
#    否则包不存在，镜像阶段会找不到 hinlink-h68k-rk3568-u-boot-rockchip.bin。
# ---------------------------------------------------------------------------
log "[5/7] U-Boot 支持"
UBOOT_PKG="$IWRT_DIR/package/boot/uboot-rockchip"
[ -d "$UBOOT_PKG" ] || die "缺少 package/boot/uboot-rockchip"

for id in $UBOOT_UPSTREAM_PATCHES; do
	for p in "$OVERLAY_DIR/patches-uboot/upstream/$id"-*.patch; do
		[ -f "$p" ] || continue
		cp -f "$p" "$UBOOT_PKG/patches/"
		echo "    + $(basename "$p") -> package/boot/uboot-rockchip/patches/"
	done
done

python3 - "$UBOOT_PKG/Makefile" <<'PY'
import io
import sys

path = sys.argv[1]
text = io.open(path, encoding="utf-8").read()

if "define U-Boot/hinlink-h68k-rk3568" in text:
    print("    Makefile 里已注册 U-Boot/hinlink-h68k-rk3568，跳过")
    raise SystemExit(0)

if "define U-Boot/rk3568/Default" not in text:
    raise SystemExit("    [error] Makefile 里没有 U-Boot/rk3568/Default，"
                     "immortalwrt 的 u-boot 打包结构变了，需要人工适配")

marker = "$(eval $(call BuildPackage/U-Boot))"
if marker not in text:
    raise SystemExit("    [error] 找不到 $(eval $(call BuildPackage/U-Boot)) 调用点")

block = """define U-Boot/hinlink-h68k-rk3568
  $(U-Boot/rk3568/Default)
  NAME:=HINLINK H68K
  BUILD_DEVICES:= \\
    hinlink_opc-h68k-a-b \\
    hinlink_opc-h68k-a-b-usb \\
    hinlink_opc-h68k-c-d-f \\
    hinlink_opc-h68k-c-d-f-usb \\
    hinlink_opc-h68k-new
endef

"""

# 必须插在 BuildPackage 之前：u-boot.mk 在展开时枚举 U-Boot/* 变量
text = text.replace(marker, block + marker, 1)
io.open(path, "w", encoding="utf-8", newline="\n").write(text)
print("    已在 uboot-rockchip/Makefile 注册 U-Boot/hinlink-h68k-rk3568")
PY

# ---------------------------------------------------------------------------
# 6) 本地软件包（aic8800 / ssd1306 / 5G 复位 / tft-display …）
#    aic8800-sdio 是 h68k-new 的板载 WiFi 驱动，必带。
# ---------------------------------------------------------------------------
log "[6/7] 合入 package/beaverfffan"
if [ -d "$OVERLAY_DIR/package/beaverfffan" ]; then
	rm -rf "$IWRT_DIR/package/beaverfffan"
	mkdir -p "$IWRT_DIR/package/beaverfffan"
	for d in "$OVERLAY_DIR"/package/beaverfffan/*; do
		name="$(basename "$d")"
		skip=0
		for x in $LOCAL_PKG_EXCLUDE; do
			[ "$name" = "$x" ] && skip=1
		done
		if [ "$skip" = "1" ]; then
			echo "    - 跳过 $name（与官方 feed 同名，避免重复定义）"
			continue
		fi
		cp -a "$d" "$IWRT_DIR/package/beaverfffan/"
		echo "    + $name"
	done
else
	warn "适配层里没有 package/beaverfffan"
fi

# ---------------------------------------------------------------------------
# 7) target config 追加（可选）
# ---------------------------------------------------------------------------
log "[7/7] target config"
if [ "$APPLY_TARGET_CONFIG" = "1" ] && [ -f "$OVL_ROCK/hinlink-config.append" ]; then
	CFG="$IWRT_ROCK/armv8/config-6.18"
	[ -f "$CFG" ] || CFG="$(ls "$IWRT_ROCK"/armv8/config-* | tail -1)"
	if ! grep -q 'HinLink begin' "$CFG"; then
		cat "$OVL_ROCK/hinlink-config.append" >> "$CFG"
		echo "    已追加到 $(basename "$CFG")"
	fi
else
	echo "    跳过（APPLY_TARGET_CONFIG=$APPLY_TARGET_CONFIG）"
fi

# ---------------------------------------------------------------------------
# 自检：机型定义引用的 DTS 必须都存在，否则编译到出图阶段才报错
# ---------------------------------------------------------------------------
log "自检"
missing=0
while read -r d; do
	[ -n "$d" ] || continue
	if [ ! -f "$DTS_DST/$d.dts" ]; then
		warn "机型引用了不存在的 DTS: $d.dts"
		missing=$((missing + 1))
	fi
done < <(grep -oE 'DEVICE_DTS[[:space:]]*:=[[:space:]]*[A-Za-z0-9_.-]+' \
	"$IWRT_ROCK/image/armv8.mk.hinlink" | awk '{print $NF}')

for d in rk3568-hinlink-h68k-a-b rk3568-hinlink-h68k-a-b-usb \
	rk3568-hinlink-h68k-c-d-f rk3568-hinlink-h68k-c-d-f-usb \
	rk3568-hinlink-h68k-new; do
	[ -f "$DTS_DST/$d.dts" ] || { warn "H68K 缺少设备树: $d.dts"; missing=$((missing + 1)); }
done

[ "$missing" -eq 0 ] || die "有 $missing 个设备树缺失，检查适配层版本与源码版本是否匹配"

echo "    机型定义数: $(grep -c 'define Device/hinlink_' "$IWRT_ROCK/image/armv8.mk.hinlink")"
echo
log "适配层合入完成"
