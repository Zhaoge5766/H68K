#!/usr/bin/env python3
"""把 Beaverfffan/immortalwrt-hinlink 适配层注入**官方** immortalwrt 源码树。

用法：
    python3 scripts/inject-hinlink.py --overlay ./overlay --tree ./immortalwrt

设计原则（每一条都对应一个真实踩过的坑）：

1. **只注入 H68K 需要的东西**。适配层覆盖 16 个机型，其中 H29K 的机型名带小数点
   （`hinlink_h29k-v1.3-1.14_rk3528`），而 OpenWrt 会把机型名原样拼成 kconfig 符号
   `CONFIG_TARGET_DEVICE_rockchip_armv8_DEVICE_<name>`，符号里出现 `.` 是非法字符。
   只保留 H68K 那 5 个 device 及其依赖的公共 device 块，从源头上避掉。

2. **board.d 走合并，不走覆盖**。`01_leds` / `02_network` 官方文件里已经有几十个
   机型的 case 分支，整文件覆盖会把它们全丢掉。合并时插在官方 `*)` 兜底**之前** ——
   插在 `*)` 之后的话永远匹配不到我们（这正是适配层上一版的真实 bug）。

3. **每一步都可重复执行**。注入脚本在 CI 里可能因为缓存/重跑被执行多次，所有追加
   操作都带标记，重复执行先删旧块再写。

4. **失败要吵**。任何一步的预期结构对不上就退出码非 0，不做"静默跳过"——
   静默跳过的后果是固件编出来了但没有网络配置，比编译失败更难查。
"""
import argparse
import glob
import io
import os
import re
import shutil
import sys

# ---------- 要注入的机型 ----------
H68K_DEVICES = [
    "hinlink_opc-h68k-a-b",
    "hinlink_opc-h68k-a-b-usb",
    "hinlink_opc-h68k-c-d-f",
    "hinlink_opc-h68k-c-d-f-usb",
    "hinlink_opc-h68k-new",
]
UBOOT_VARIANT = "hinlink-h68k-rk3568"
UBOOT_DEVICE_NAME = "HINLINK H68K"

# ---------- 标记 ----------
MK_BEGIN = "# ===== HinLink 适配层 begin（scripts/inject-hinlink.py 自动写入，勿手改）====="
MK_END = "# ===== HinLink 适配层 end ====="
UB_BEGIN = "# ===== HinLink u-boot begin（inject-hinlink.py 自动写入，勿手改）====="
UB_END = "# ===== HinLink u-boot end ====="
CFG_BEGIN = "# ============ HinLink begin ============"
CFG_END = "# ============ HinLink end ============"


def log(msg):
    print(msg, flush=True)


def die(msg):
    print("ERROR: %s" % msg, flush=True)
    sys.exit(1)


def rd(p):
    return io.open(p, encoding="utf-8").read()


def wr(p, text):
    d = os.path.dirname(p)
    if d:
        os.makedirs(d, exist_ok=True)
    io.open(p, "w", encoding="utf-8", newline="\n").write(text)


def strip_block(text, begin, end):
    """删掉（可能多次出现的）带标记块，用于幂等重写。"""
    pat = re.compile(r"\n*" + re.escape(begin) + r".*?" + re.escape(end) + r"\n", re.S)
    return pat.sub("\n", text)


# 适配层里有 58 个文件是 CRLF（Makefile / init.d 脚本 / .patch 全中）。
# 直接拷进 Linux 树会出两类问题：
#   · init.d/uci-defaults 脚本 —— 刷机后报 /bin/sh^M: bad interpreter
#   · *.patch —— patch -p1 报 "different line endings"，内核阶段直接失败
# 所以所有文本文件在拷贝时统一转 LF；二进制只按扩展名放行。
BINARY_EXT = (".dtb", ".bin", ".img", ".gz", ".xz", ".zst", ".png", ".jpg",
              ".jpeg", ".gif", ".ico", ".woff", ".woff2", ".ttf", ".so", ".o", ".a")


def copy_lf(src, dst, exec_bit=False):
    d = os.path.dirname(dst)
    if d:
        os.makedirs(d, exist_ok=True)
    if src.lower().endswith(BINARY_EXT):
        shutil.copy2(src, dst)
    else:
        data = io.open(src, "rb").read()
        data = data.replace(b"\r\n", b"\n").replace(b"\r", b"\n")
        io.open(dst, "wb").write(data)
    if exec_bit:
        os.chmod(dst, 0o755)


# =====================================================================
# 1. DTS / DTSI
# =====================================================================
def step_dts(ovl, tree):
    src = os.path.join(ovl, "target/linux/rockchip/files/arch/arm64/boot/dts/rockchip")
    dst = os.path.join(tree, "target/linux/rockchip/files/arch/arm64/boot/dts/rockchip")
    if not os.path.isdir(src):
        die("适配层里没有 %s" % src)
    os.makedirs(dst, exist_ok=True)
    n = 0
    for f in sorted(os.listdir(src)):
        p = os.path.join(src, f)
        if not os.path.isfile(p):
            continue
        if f.startswith("vendor-"):        # 厂商 dtb，仅供参考，不能进内核树
            continue
        copy_lf(p, os.path.join(dst, f))
        n += 1
    log("  DTS/DTSI  %d 个文件 -> target/linux/rockchip/files/..." % n)


# =====================================================================
# 2. image/armv8.mk：只追加 H68K 需要的 device 定义
# =====================================================================
def parse_devices(text):
    """解析 armv8.mk 里的 `define Device/x` ... `endef`，返回 [(name, 文本)]。"""
    lines = text.splitlines(True)
    out = []
    i = 0
    while i < len(lines):
        m = re.match(r"^define\s+Device/([^\s#]+)\s*$", lines[i])
        if not m:
            i += 1
            continue
        name = m.group(1)
        j = i
        while j < len(lines) and not re.match(r"^endef\s*$", lines[j]):
            j += 1
        if j >= len(lines):
            die("Device/%s 没有配对的 endef" % name)
        out.append((name, "".join(lines[i:j + 1])))
        i = j + 1
    return out


def step_armv8_mk(ovl, tree):
    ovl_mk = os.path.join(ovl, "target/linux/rockchip/image/armv8.mk.hinlink")
    tgt_mk = os.path.join(tree, "target/linux/rockchip/image/armv8.mk")
    if not os.path.isfile(ovl_mk):
        die("适配层里没有 image/armv8.mk.hinlink")
    if not os.path.isfile(tgt_mk):
        die("官方树里没有 target/linux/rockchip/image/armv8.mk（内核版本/目录结构变了？）")

    ovl_text = rd(ovl_mk)
    blocks = dict(parse_devices(ovl_text))
    official = {n for n, _ in parse_devices(rd(tgt_mk))}

    # ★ 光有 `define Device/x` 不够 —— include/image.mk 只遍历 TARGET_DEVICES：
    #     $(foreach device,$(TARGET_DEVICES),$(call Device,$(device)))
    #   少了 `TARGET_DEVICES += x` 这行，机型压根不会出现在 menuconfig 里，
    #   `.config` 里的 CONFIG_TARGET_DEVICE_... 会被 kconfig 当未知符号丢掉，
    #   症状是 defconfig 能过、但一个机型都没选中。
    regs = []
    for line in ovl_text.splitlines():
        m = re.match(r"^TARGET_DEVICES\s*\+=\s*(.+?)\s*$", line)
        if m:
            regs.append(m.group(1).split())

    # H68K 五个机型 + 递归解析它们引用的 $(Device/xxx)
    keep, todo = [], list(H68K_DEVICES)
    while todo:
        name = todo.pop(0)
        if name in keep:
            continue
        if name not in blocks:
            if name in official:
                continue          # 官方树里的基座（如 Device/rk3568），不用我们提供
            die("Device/%s 既不在适配层也不在官方树里" % name)
        keep.append(name)
        for ref in re.findall(r"\$\(Device/([^\s)]+)", blocks[name]):
            if ref not in keep:
                todo.append(ref)

    # 按适配层原文件顺序输出，保证基座先于引用者定义 —— make 是顺序求值的，
    # device 块里用 $(Device/x) 时 x 必须已经定义过
    order = [n for n in blocks if n in keep]
    if len(order) != len(keep):
        die("内部错误：有序表与保留集不一致")

    keep_set = set(order)
    reg_out = []
    for names in regs:
        kept = [n for n in names if n in keep_set]
        if kept:
            reg_out.append("TARGET_DEVICES += %s" % " ".join(kept))

    # 每个要编的机型都必须有注册行，否则它不会出现在 target 的机型列表里
    registered = {n for names in regs for n in names}
    miss = [d for d in H68K_DEVICES if d not in registered]
    if miss:
        die("适配层里这些机型没有 TARGET_DEVICES 注册：%s" % ", ".join(miss))

    body = "\n".join(blocks[n].rstrip("\n") for n in order)
    body += "\n\n" + "\n".join(reg_out)

    text = strip_block(rd(tgt_mk), MK_BEGIN, MK_END).rstrip("\n")
    text += "\n\n%s\n%s\n%s\n" % (MK_BEGIN, body, MK_END)
    wr(tgt_mk, text)
    log("  armv8.mk  %d 个 device 块 + %d 条注册：%s"
        % (len(order), len(reg_out), ", ".join(order)))

    # 自检：注册行必须真的落到文件里
    written = rd(tgt_mk)
    for d in H68K_DEVICES:
        if not re.search(r"^TARGET_DEVICES \+=.*\b%s\b" % re.escape(d), written, re.M):
            die("%s 的 TARGET_DEVICES 注册没写进去" % d)

    # 每个 H68K 机型的 DEVICE_DTS 必须真的存在，否则会到 image 阶段才报错
    dts_dir = os.path.join(tree, "target/linux/rockchip/files/arch/arm64/boot/dts/rockchip")
    for dev in H68K_DEVICES:
        m = re.search(r"^\s*DEVICE_DTS\s*:?=\s*(\S+)", blocks[dev], re.M)
        if not m:
            die("Device/%s 没有 DEVICE_DTS" % dev)
        f = os.path.join(dts_dir, m.group(1) + ".dts")
        if not os.path.isfile(f):
            die("Device/%s 的 DEVICE_DTS=%s，但 %s 不存在" % (dev, m.group(1), f))


# =====================================================================
# 3. board.d：合并 01_leds / 02_network，另拷 03_hinlink-lan-ip
# =====================================================================
def case_blocks(text):
    out, i = [], 0
    while True:
        m = re.search(r'^[ \t]*case\s+"?\$board"?\s+in\s*\n', text[i:], re.M)
        if not m:
            break
        bs = i + m.end()
        e = re.search(r"^[ \t]*esac\n", text[bs:], re.M)
        if not e:
            break
        out.append((bs, bs + e.start()))
        i = bs + e.end()
    return out


def step_boardd(ovl, tree):
    src = os.path.join(ovl, "target/linux/rockchip/armv8/base-files/etc/board.d")
    dst = os.path.join(tree, "target/linux/rockchip/armv8/base-files/etc/board.d")
    if not os.path.isdir(src):
        die("适配层里没有 base-files/etc/board.d")

    for name in ("01_leds", "02_network"):
        base_p, add_p = os.path.join(dst, name), os.path.join(src, name)
        base, add = rd(base_p), rd(add_p)

        if re.search(r"hinlink,|hinlink_opc-h68k", base):
            log("  board.d  %s 已含 hinlink 条目，跳过合并" % name)
            continue

        bb, ab = case_blocks(base), case_blocks(add)
        if len(bb) != len(ab) or not bb:
            # 这里**不能**跳过。跳过 = 固件里我们的机型没有网络/LED 配置，
            # 刷进去是「能启动但没网」，比编译失败更难排查。
            die("%s 的 case 块数量对不上（官方 %d / 适配层 %d），"
                "适配层需要按新版官方文件更新" % (name, len(bb), len(ab)))

        out = base
        for (bbs, bee), (as_, aee) in reversed(list(zip(bb, ab))):
            body = add[as_:aee]
            if re.search(r"^[ \t]*\*\)", body, re.M):
                die("%s 的适配层 case 块里有 `*)` 兜底，会吃掉官方其它机型" % name)
            # 统一缩进一层，跟官方风格一致
            body = "".join(("\t" + ln) if ln.strip() else ln for ln in body.splitlines(True))

            m = re.search(r"^[ \t]*\*\)[ \t]*\n", base[bbs:bee], re.M)
            pos = bbs + (m.start() if m else len(base[bbs:bee]))
            out = out[:pos] + body + out[pos:]

        wr(base_p, out)
        # 合并后自检：h68k 分支必须落在官方 `*)` 之前
        merged = rd(base_p)
        for b0, b1 in case_blocks(merged):
            chunk = merged[b0:b1]
            i_h = chunk.find("hinlink_opc-h68k")
            if i_h < 0:
                continue
            m = re.search(r"^[ \t]*\*\)[ \t]*\n", chunk, re.M)
            if m and m.start() < i_h:
                die("%s 里 hinlink 分支被插到了 *) 之后，永远不会生效" % name)
        log("  board.d  %s 合并 %d 个 case 块" % (name, len(bb)))

    # 其它 board.d 文件（03_hinlink-lan-ip 之类）整文件拷贝
    n = 0
    for f in sorted(os.listdir(src)):
        if f in ("01_leds", "02_network"):
            continue
        p = os.path.join(src, f)
        if not os.path.isfile(p):
            continue
        dp = os.path.join(dst, f)
        copy_lf(p, dp, exec_bit=True)
        n += 1
    log("  board.d  另拷 %d 个新文件（已置 0755）" % n)


# =====================================================================
# 4. 内核补丁
# =====================================================================
def kernel_ver(tree):
    mk = os.path.join(tree, "target/linux/rockchip/Makefile")
    m = re.search(r"^KERNEL_PATCHVER\s*:?=\s*(\S+)", rd(mk), re.M)
    if not m:
        die("读不出 target/linux/rockchip/Makefile 里的 KERNEL_PATCHVER")
    return m.group(1)


def step_kpatch(ovl, tree):
    ver = kernel_ver(tree)
    src = os.path.join(ovl, "patches")
    dst = os.path.join(tree, "target/linux/rockchip/patches-%s" % ver)
    if not os.path.isdir(src):
        die("适配层里没有 patches/")
    os.makedirs(dst, exist_ok=True)
    names = []
    for f in sorted(os.listdir(src)):
        if not f.endswith(".patch"):
            continue
        copy_lf(os.path.join(src, f), os.path.join(dst, f))
        names.append(f)
    log("  内核补丁  注入 patches-%s：%s" % (ver, ", ".join(names)))


# =====================================================================
# 5. target 内核 config 追加（FB / fbtft 内建）
# =====================================================================
def step_kconfig(ovl, tree):
    src = os.path.join(ovl, "target/linux/rockchip/hinlink-config.append")
    if not os.path.isfile(src):
        log("  config    (适配层没有 hinlink-config.append，跳过)")
        return
    app = rd(src)
    # 只取 begin/end 之间的实际配置行，前面的注释是给适配层自己看的
    m = re.search(re.escape(CFG_BEGIN) + r"(.*?)" + re.escape(CFG_END), app, re.S)
    if not m:
        die("hinlink-config.append 里没有 %s ... %s 标记" % (CFG_BEGIN, CFG_END))
    body = m.group(1).strip("\n")

    armv8 = os.path.join(tree, "target/linux/rockchip/armv8")
    files = []
    for f in sorted(os.listdir(armv8)):
        if f.startswith("config-"):
            files.append(os.path.join(armv8, f))
    if not files:
        die("target/linux/rockchip/armv8/ 下没有 config-*")

    block = "%s\n%s\n%s\n" % (CFG_BEGIN, body, CFG_END)
    for p in files:
        t = strip_block(rd(p), CFG_BEGIN, CFG_END).rstrip("\n")
        wr(p, t + "\n\n" + block)
    log("  config    追加 %d 行到 %s" % (len(body.splitlines()), ", ".join(os.path.basename(p) for p in files)))


# =====================================================================
# 6. 本地包 package/beaverfffan
# =====================================================================
def tree_pkg_names(tree):
    """扫出树里已有的 PKG_NAME -> 目录，用于识别"上游已经收录了同名包"。"""
    found = {}
    skip = os.path.join(tree, "package", "beaverfffan")
    pats = ("package/*/*/Makefile", "package/*/*/*/Makefile")
    for pat in pats:
        for mk in glob.glob(os.path.join(tree, pat)):
            d = os.path.dirname(mk)
            if d == skip or d.startswith(skip + os.sep):
                continue          # 我们自己要放的位置，不算
            try:
                m = re.search(r"^PKG_NAME\s*:?=\s*(\S+)", rd(mk), re.M)
            except (UnicodeDecodeError, OSError):
                continue
            if m:
                found.setdefault(m.group(1), d)
    return found


def step_packages(ovl, tree):
    src = os.path.join(ovl, "package/beaverfffan")
    if not os.path.isdir(src):
        log("  packages  (适配层没有 package/beaverfffan，跳过)")
        return
    dst = os.path.join(tree, "package/beaverfffan")
    if os.path.isdir(dst):
        shutil.rmtree(dst)          # 整目录重建：避免改名后旧文件残留
    os.makedirs(dst, exist_ok=True)

    # ★ 上游会不断把适配层里的包合进自己的树（aic8800 就是这样）。
    #   两处同名包 = 同一个 PKG_NAME、同一个 build_dir，互相踩，
    #   报错还是 "package/xxx failed to build"，看不出是重复导致的。
    #   所以按 PKG_NAME 查一遍：树里已有的一律跳过，用上游那份。
    existing = tree_pkg_names(tree)
    copied, skipped = [], []
    for name in sorted(os.listdir(src)):
        sp = os.path.join(src, name)
        if not os.path.isdir(sp):
            continue
        mk = os.path.join(sp, "Makefile")
        pkg = None
        if os.path.isfile(mk):
            m = re.search(r"^PKG_NAME\s*:?=\s*(\S+)", rd(mk), re.M)
            pkg = m.group(1) if m else name
        if pkg and pkg in existing:
            skipped.append("%s（上游已有：%s）" % (name, os.path.relpath(existing[pkg], tree)))
            continue

        n = 0
        for root, _dirs, files in os.walk(sp):
            rel = os.path.relpath(root, sp)
            od = os.path.join(dst, name) if rel == "." else os.path.join(dst, name, rel)
            os.makedirs(od, exist_ok=True)
            for f in files:
                relposix = (rel.replace(os.sep, "/") + "/" + f)
                exec_bit = any(k in relposix for k in
                               ("etc/init.d/", "etc/uci-defaults/", "usr/libexec/", "hotplug.d/"))
                copy_lf(os.path.join(root, f), os.path.join(od, f), exec_bit=exec_bit)
                n += 1
        copied.append("%s(%d)" % (name, n))

    log("  packages  注入 %s" % ", ".join(copied))
    if skipped:
        for s in skipped:
            log("  packages  跳过 %s" % s)


# =====================================================================
# 7. u-boot：注册变体 + 补上 defconfig/uboot-dtsi
# =====================================================================
def step_uboot(ovl, tree):
    mk_p = os.path.join(tree, "package/boot/uboot-rockchip/Makefile")
    if not os.path.isfile(mk_p):
        die("官方树里没有 package/boot/uboot-rockchip/Makefile")

    text = strip_block(rd(mk_p), UB_BEGIN, UB_END).rstrip("\n")
    anchor = "$(eval $(call BuildPackage/U-Boot))"
    if anchor not in text:
        die("uboot-rockchip/Makefile 里找不到 %s（包结构变了）" % anchor)
    if "define U-Boot/rk3568/Default" not in text:
        die("uboot-rockchip/Makefile 里没有 U-Boot/rk3568/Default，"
            "适配层的写法需要跟着官方改")

    devs = " \\\n    ".join(H68K_DEVICES)
    block = "\n".join([
        UB_BEGIN,
        "define U-Boot/%s" % UBOOT_VARIANT,
        "  $(U-Boot/rk3568/Default)",
        "  NAME:=%s" % UBOOT_DEVICE_NAME,
        "  BUILD_DEVICES:= \\",
        "    %s" % devs,
        "endef",
        "",
        "UBOOT_TARGETS += %s" % UBOOT_VARIANT,
        UB_END,
        "",
    ])
    text = text.replace(anchor, block + "\n" + anchor, 1)
    wr(mk_p, text)
    log("  u-boot    注册 U-Boot/%s（BUILD_DEVICES %d 个机型）" % (UBOOT_VARIANT, len(H68K_DEVICES)))

    # u-boot 2026.10 自带 dts/upstream/.../rk3568-hinlink-h68k.dts，
    # 但缺 configs/hinlink-h68k-rk3568_defconfig 和 arch/arm/dts/...-u-boot.dtsi，
    # 官方补丁 106 正好补这两个（纯新增文件，不依赖上下文，安全）。
    src = os.path.join(ovl, "patches-uboot/upstream")
    dst = os.path.join(tree, "package/boot/uboot-rockchip/patches")
    os.makedirs(dst, exist_ok=True)
    n = 0
    for f in sorted(os.listdir(src)):
        if not f.endswith(".patch"):
            continue
        # 只要 H66K/H68K 那个（106）；107 是 H28K，108/109 是其它板子，用不到
        if "HINLINK-H66K-H68K" not in f:
            continue
        copy_lf(os.path.join(src, f), os.path.join(dst, f))
        n += 1
        log("  u-boot    + %s" % f)
    if n == 0:
        die("适配层 patches-uboot/upstream 里没有 H66K/H68K 的补丁")


# =====================================================================
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--overlay", required=True, help="Beaverfffan/immortalwrt-hinlink 的本地路径")
    ap.add_argument("--tree", required=True, help="官方 immortalwrt 源码树")
    a = ap.parse_args()

    ovl, tree = os.path.abspath(a.overlay), os.path.abspath(a.tree)
    for p in (ovl, tree):
        if not os.path.isdir(p):
            die("找不到目录 %s" % p)

    log("[1/7] DTS / DTSI")
    step_dts(ovl, tree)
    log("[2/7] 机型定义 image/armv8.mk")
    step_armv8_mk(ovl, tree)
    log("[3/7] board.d 网络 / LED")
    step_boardd(ovl, tree)
    log("[4/7] 内核补丁")
    step_kpatch(ovl, tree)
    log("[5/7] target 内核 config（FB / fbtft 内建）")
    step_kconfig(ovl, tree)
    log("[6/7] 本地包 package/beaverfffan")
    step_packages(ovl, tree)
    log("[7/7] u-boot")
    step_uboot(ovl, tree)
    log("注入完成")


if __name__ == "__main__":
    main()
