#!/usr/bin/env python3
"""按白名单裁剪机型定义文件（armv8.mk.hinlink）。

为什么要裁：

1) OpenWrt 会把每个 `define Device/xxx` 原样变成 kconfig 符号
   `CONFIG_TARGET_<board>_<sub>_DEVICE_xxx`（见 include/image.mk 的
   Device/DumpInfo → scripts/metadata.pm，全程没有做字符替换）。
   适配层里 H29K 的机型名带小数点（hinlink_h29k-v1.3-1.14_rk3528），
   kconfig 符号里出现 `.` 会让 `make defconfig` 直接报语法错误 ——
   整个 target 都生成不出 .config，跟编哪个机型无关。

2) 只编 H68K 时，其它机型的 DEVICE_PACKAGES（触摸屏、5G、NVMe…）
   会把一堆无关键编进来，既拖时间也放大失败面。

用法：
    filter-devices.py <源 mk> <目标 mk> <保留的 Device 名...>
"""

import io
import re
import sys

DEF_RE = re.compile(r"^define\s+Device/(\S+)\s*$")


def main():
    if len(sys.argv) < 4:
        sys.exit("用法: filter-devices.py <源 mk> <目标 mk> <保留的 Device 名...>")

    src, dst = sys.argv[1], sys.argv[2]
    keep = set(sys.argv[3:])

    lines = io.open(src, encoding="utf-8").read().split("\n")
    out = []
    kept, dropped = [], []
    i = 0

    while i < len(lines):
        m = DEF_RE.match(lines[i])
        if not m:
            out.append(lines[i])
            i += 1
            continue

        name = m.group(1)
        block = [lines[i]]
        i += 1
        while i < len(lines):
            block.append(lines[i])
            if lines[i].strip() == "endef":
                i += 1
                break
            i += 1

        if name in keep:
            out.extend(block)
            kept.append(name)
            continue

        # 丢掉紧随其后的 TARGET_DEVICES += <name>（可能有多行）
        while i < len(lines):
            if re.match(r"^\s*TARGET_DEVICES\s*\+=\s*%s\s*$" % re.escape(name), lines[i]):
                i += 1
                continue
            break
        dropped.append(name)

    io.open(dst, "w", encoding="utf-8", newline="\n").write("\n".join(out))

    print("    保留机型 %d 个: %s" % (len(kept), " ".join(kept)))
    if dropped:
        print("    裁掉机型 %d 个: %s" % (len(dropped), " ".join(dropped)))
    missing = keep - set(kept)
    if missing:
        print("    [warn] 白名单里这些名字在源文件中不存在: %s" % " ".join(sorted(missing)))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
