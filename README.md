# H68K 固件自动编译

用 GitHub Actions 编译 **HinLink H68K** 的 ImmortalWrt 固件，编完推送到
[Zhaoge5766/H68K](https://github.com/Zhaoge5766/H68K)。

## 用的什么源码

**官方 [immortalwrt/immortalwrt](https://github.com/immortalwrt/immortalwrt)（master）
+ [Beaverfffan/immortalwrt-hinlink](https://github.com/Beaverfffan/immortalwrt-hinlink) 设备适配层**。

也就是说：内核、u-boot、所有通用包都来自官方树，能跟着上游更新；适配层只提供
H68K 专属的那部分，在 CI 里现场注入。注入了什么：

| 内容 | 数量 / 说明 |
| --- | --- |
| 设备树 `*.dts` / `*.dtsi` | 28 个（含 H68K 5 个变体的 dts 和公共 `rk3568-hinlink-opc.dtsi`） |
| 机型定义 | 5 个 H68K 变体 + 它们依赖的 5 个公共 device 块 |
| `board.d` | `01_leds`、`02_network` 两个文件**合并**（不是覆盖），另加 `03_hinlink-lan-ip` |
| 内核补丁 | 3 个，进 `target/linux/rockchip/patches-6.18/` |
| 内核 config | FB / fbtft / rfkill-gpio 内建段，追加进 `armv8/config-6.18` |
| u-boot | 注册 `U-Boot/hinlink-h68k-rk3568` + 补上 `defconfig`（官方 u-boot 2026.10 只自带 dts，没 defconfig） |
| 本地包 | 7 个：`aic8800`、`fancontrol`、`luci-app-fancontrol`、`luci-app-oled`、`luci-app-hinlink-modem-hardreset`、`kmod-input-touchscreen-axs5106`、`tft-display` |

注入逻辑在 `scripts/inject-hinlink.py`，只有标准库依赖。

## 目录

```
.github/workflows/build-h68k.yml   工作流
scripts/inject-hinlink.py          适配层注入（含各类校验）
configs/h68k.config                编译种子配置（只管目标和机型）
diy-part1.sh                       feeds 之前的自定义钩子
diy-part2.sh                       feeds 之后：清同名 feed 包 + 生成 .config + defconfig
```

## 怎么用

推到 `Zhaoge5766/H68K` 之后：

- **手动**：Actions → Build H68K → Run workflow。可以填
  `iwrt_ref`（官方源码分支）、`overlay_ref`（适配层分支）、`devices`、`publish`。
- **定时**：每周六 04:00（北京时间）跟一次上游。
- **推送**：改到工作流 / `scripts/` / `configs/` / `diy-part*.sh` 时自动跑一次。

不需要配任何 secret —— 工作流就在 `Zhaoge5766/H68K` 里，用的是内置
`GITHUB_TOKEN`（已声明 `permissions: contents: write`）。要推到别的仓库才需要
配 `PUSH_TOKEN`。

### 机型

`devices` 留空 = 只编 `h68k-new`。给多个则一次编完（共用内核和 rootfs）：

```
h68k-a-b  h68k-a-b-usb  h68k-c-d-f  h68k-c-d-f-usb  h68k-new
```

设备名是 `hinlink_opc-h68k-*`（命名约定：无后缀 = SATA，`-usb` = USB3.0；
RK3568 上 sata0 和 USB3.0 抢同一颗 combphy0，硬件二选一，所以是两个变体）。
也可以直接写完整 device 名。

## 产物在哪

- **Release**：`https://github.com/Zhaoge5766/H68K/releases` —— 每次一个 tag
  （`h68k-YYYYMMDD-<run号>`），带镜像 + `.manifest` + `.buildinfo` + `sha256sums.txt`。
- **`firmware` 分支**：只保留最近一次，单提交强推，仓库不会膨胀，`main` 不受影响。
- **Actions Artifacts**：保留 30 天。

刷机：

```sh
sysupgrade -n xxx-squashfs-sysupgrade.img.gz      # 已经是本固件
# 原厂首次刷：用 -factory.img.gz，按机型走线刷 / TF 卡刷
```

首次进系统 LAN 口 `192.168.100.1`，无密码；5G 模组控制面板在「网络 → 5G复位」。

## 本地复现

```sh
git clone --depth 1 https://github.com/immortalwrt/immortalwrt.git
git clone --depth 1 https://github.com/Beaverfffan/immortalwrt-hinlink.git overlay
python3 scripts/inject-hinlink.py --overlay overlay --tree immortalwrt

cd immortalwrt
./scripts/feeds update -a && ./scripts/feeds install -a
DEVICES="h68k-new" CONFIG_SEED=../configs/h68k.config bash ../diy-part2.sh
make -j$(nproc) download && make -j$(nproc)
```

产物在 `bin/targets/rockchip/armv8/`。

主机依赖里 **`python3-pyelftools` 不能少**（u-boot rockchip 在 `make prereq`
里检查它，缺了直接 `Please install the Python3 elftools module`）：

```sh
sudo apt install build-essential clang flex bison g++ gawk gettext \
  gcc-multilib g++-multilib libncurses-dev libssl-dev zlib1g-dev \
  python3-dev python3-setuptools python3-pyelftools rsync swig unzip \
  file wget bzip2 patch perl time device-tree-compiler bc
```

## 五个踩过的坑（都已写进脚本，改之前先读）

**1. `board.d` 只能合并，不能覆盖。**
官方 `01_leds` / `02_network` 里已经有几十个机型的 case 分支，整文件覆盖会把它们
全丢掉。而且合并必须插在官方 `*)` 兜底**之前** —— 插在之后的话 `*)` 先匹配到我们
所有机型，我们的分支永远不执行，症状是「能启动但没网、灯不亮」。
`inject-hinlink.py` 里带合并后自检，插错位置直接报错退出。

**2. 适配层里有 58 个文件是 CRLF。**
包括 `init.d` 脚本、包 `Makefile`、`*.patch`。直接拷进 Linux 树会出两类问题：
开机脚本报 `/bin/sh^M: bad interpreter`；补丁报 `different line endings` 直接套不上。
所以注入时所有文本文件统一转 LF。

**3. feeds 同名包会静默覆盖本地包。**
`feeds install -a` 会建出 `package/feeds/packages/fancontrol`、
`package/feeds/luci/luci-app-oled` 这些软链，OpenWrt 按字母序扫 `package/`，
`feeds` 晚于 `beaverfffan` 加载 ⇒ 同名包被 feed 那份覆盖，**编译不报错**，但装进
固件的是上游版（温控默认关、OLED 界面拿 `eth0` 而不是 5G 的 `wwan0`）。
`diy-part2.sh` 第一步就是删这些软链。

**4. 只注入 H68K 需要的东西。**
适配层覆盖 16 个机型，其中 H29K 的机型名带小数点（`hinlink_h29k-v1.3-1.14_rk3528`），
而 OpenWrt 会把机型名原样拼成 kconfig 符号，符号里出现 `.` 是非法字符。
所以注入器按 H68K 那 5 个 device 做依赖解析，其它机型不进来。

**5. `-factory` 和 `-sysupgrade` 别搞混。**
原厂固件第一次刷要用 `-factory.img.gz`（走线刷 / TF 卡），已经在跑本固件的机器
用 `-sysupgrade.img.gz` 直接升级。两个都在 Release 里。

## 用 `-full` 整树编不行吗

行，但那是 Beaverfffan 维护的一棵**完整 immortalwrt 树**（内核、uboot、通用包全是他
fork 那份的），上游一更新就得等他把 rebase 做完。这套流程里官方源码只取 master 的
当次提交，适配层单独更新，两边解耦。
