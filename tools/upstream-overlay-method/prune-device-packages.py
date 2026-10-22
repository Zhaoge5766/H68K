#!/usr/bin/env python3
"""剔除机型定义里"当前源码树不存在"的软件包名。

背景：immortalwrt-hinlink 的机型定义是跨版本维护的，里面的 DEVICE_PACKAGES
按某个时间点的包名清单写成。immortalwrt / OpenWrt 会增删 kmod 名字
（例如 kmod-mt7922-firmware 就是 6.13 之后才拆出来的独立包），一旦清单里
留下一个不存在的名字，编译不会在 defconfig 阶段报错，而是在**镜像阶段**
（已经烧掉一小时之后）才失败：

    Package kmod-xxx is missing

所以这里在 defconfig 之后拿 tmp/.packageinfo 的真实包名做一次对照过滤，
把不存在的名字摘掉并打印出来，把这类"编译到最后一刻才炸"变成一条警告。

用法：
    prune-device-packages.py <armv8.mk.hinlink> <tmp/.packageinfo>
"""

import io
import os
import re
import sys

ASSIGN_RE = re.compile(r"^(\s*DEVICE_PACKAGES\s*[:+]=\s*)(.*)$")


def load_known(path):
    names = set()
    with io.open(path, encoding="utf-8", errors="replace") as fp:
        for line in fp:
            m = re.match(r"^Package:\s*(\S+)\s*$", line)
            if m:
                names.add(m.group(1))
    return names


def main():
    if len(sys.argv) != 3:
        sys.exit("用法: prune-device-packages.py <mk 文件> <.packageinfo>")

    mk_path, info_path = sys.argv[1], sys.argv[2]

    if not os.path.isfile(info_path):
        print("    [warn] 找不到 %s，跳过滤包检查" % info_path)
        return 0
    if not os.path.isfile(mk_path):
        print("    [warn] 找不到 %s，跳过" % mk_path)
        return 0

    known = load_known(info_path)
    if not known:
        print("    [warn] .packageinfo 里没解析到任何包名，跳过")
        return 0

    text = io.open(mk_path, encoding="utf-8").read()
    out = []
    removed = []
    in_assign = False

    for line in text.split("\n"):
        m = ASSIGN_RE.match(line)
        continuing = in_assign

        if m:
            head, body = m.group(1), m.group(2)
            in_assign = True
        elif continuing:
            stripped = line.lstrip()
            head = line[: len(line) - len(stripped)]
            body = stripped
        else:
            out.append(line)
            continue

        has_cont = body.rstrip().endswith("\\")
        if has_cont:
            body = body.rstrip()[:-1].rstrip()
        # 保留行尾注释（适配层里 DEVICE_PACKAGES 行尾没有注释，做个保护）
        comment = ""
        if " #" in body:
            body, comment = body.split(" #", 1)
            comment = " #" + comment
        in_assign = has_cont

        kept = []
        for tok in body.split():
            # 宏引用（$(Device/xxx)）、带 + 的依赖标记、版本约束一律原样保留
            if any(ch in tok for ch in "$()=:,"):
                kept.append(tok)
                continue
            if tok not in known:
                removed.append(tok)
                continue
            kept.append(tok)

        new_body = " ".join(kept)
        new_line = (head + new_body).rstrip()
        if has_cont:
            new_line = new_line + " \\" if new_body else "\\"
        elif not new_body and head:
            # DEVICE_PACKAGES += 后面空了，去掉整行更干净
            continue
        out.append(new_line + comment)

    if not removed:
        print("    包名全部存在，无需剔除")
        return 0

    io.open(mk_path, "w", encoding="utf-8", newline="\n").write("\n".join(out))
    uniq = sorted(set(removed))
    print("    已剔除 %d 个当前源码树不存在的包名：" % len(uniq))
    for name in uniq:
        print("      - %s" % name)
    return 0


if __name__ == "__main__":
    sys.exit(main())
