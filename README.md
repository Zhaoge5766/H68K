# H68K 固件自动编译

用 GitHub Actions 编译 **HinLink H68K 全系**（5 个变体）的 ImmortalWrt 固件，
预装 PassWall 2 / Nikki / OpenClash / DiskMan，编完推送到
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

## 机型

全系 5 个，一次编完（**共用同一份内核和同一个 u-boot 变体**，只多拼几次镜像）：

| `devices` 里的名字 | 机器 |
| --- | --- |
| `h68k-a-b` | A/B 板（2022，双千兆 2 口）+ SATA |
| `h68k-a-b-usb` | A/B 板，USB3.0 |
| `h68k-c-d-f` | C/D/F 板（2022~2023.4，四网口）+ SATA |
| `h68k-c-d-f-usb` | C/D/F 板，USB3.0 |
| `h68k-new` | 新机器（2023 末~2024），SATA 与 USB3.0 可同时用 |

无后缀 = SATA，`-usb` = USB3.0：RK3568 上 sata0 与 USB3.0 抢同一颗 combphy0，
硬件二选一，所以老机器拆成两个变体。也可以直接写完整 device 名
（`hinlink_opc-h68k-new`）。

## 预装的插件

| `plugins` 里的名字 | 包含的包 | 来源 |
| --- | --- | --- |
| `passwall2` | `luci-app-passwall2` | `Openwrt-Passwall/openwrt-passwall2` |
| `nikki` | `luci-app-nikki` + `nikki` + `mihomo-meta` | `nikkinikki-org/OpenWrt-nikki` |
| `openclash` | `luci-app-openclash` | 官方 luci feed 自带 |
| `diskman` | `luci-app-diskman` | 官方 luci feed 自带 |

它们的**依赖**（`xray-core` / `sing-box` / `chinadns-ng` / `geoview` / `tcping` /
`lyaml` / `v2ray-geodata` / `haproxy` / `ruby` / `yq` / `parted` / `exfatprogs` …）
官方 packages feed 里都有，版本也对得上（`geoview` 两边都是 0.2.8），所以只加
"没有的那部分" feed。`dnsmasq-full` 本来就是 `DEVICE_TYPE=router` 的默认包，
OpenClash 要的 ipset / nftset 能力直接可用。

两点注意：

- **SSR 被关掉了**：passwall2 的 `INCLUDE_ShadowsocksR_Libev_Client` 默认开，
  但 `shadowsocksr-libev` 只在 `openwrt-passwall-packages` 里，而那个 feed
  不能加（见下面第 6 条）。`diy-part2.sh` 会自动把这个开关写死为 off。
- **三个代理只能开一个**：OpenClash、PassWall 2、Nikki 都会接管 DNS 和
  nftables，同时开会互相打架。装在一起是为了随时换，不是为了一起跑。

## 目录

```
.github/workflows/build-h68k.yml   工作流
scripts/inject-hinlink.py          适配层注入（含各类校验）
configs/h68k.config                编译种子配置（只钉平台，机型/插件由脚本管）
diy-part1.sh                       feeds 之前：加插件 feed + 改源码字面量
diy-part2.sh                       feeds 之后：清同名 feed 包 + 选机型 + 开插件 + defconfig
```

## 怎么用

推到 `Zhaoge5766/H68K` 之后：

- **手动**：Actions → Build H68K → Run workflow。可以填
  `iwrt_ref`（官方源码分支）、`overlay_ref`（适配层分支）、`devices`、`plugins`、`publish`。
- **定时**：每周六 04:00（北京时间）跟一次上游。
- **推送**：改到工作流 / `scripts/` / `configs/` / `diy-part*.sh` 时自动跑一次。

两个输入留空就是全系 / 全插件：

```
devices:  h68k-a-b h68k-a-b-usb h68k-c-d-f h68k-c-d-f-usb h68k-new
plugins:  passwall2 nikki openclash diskman
```

想只编一个机型：`devices` 填 `h68k-new`。想一个插件都不加：`plugins` 填 `none`。

不需要配任何 secret —— 工作流就在 `Zhaoge5766/H68K` 里，用的是内置
`GITHUB_TOKEN`（已声明 `permissions: contents: write`）。要推到别的仓库才需要
配 `PUSH_TOKEN`。

首次全量编译（无缓存、5 机型 + 4 插件，含 ruby / sing-box / xray / mihomo 的
编译）大约 2.5~3.5 小时；有 `dl/` + ccache 缓存后第二次快很多。

## 产物在哪

- **Release**：`https://github.com/Zhaoge5766/H68K/releases` —— 每次一个 tag
  （`h68k-YYYYMMDD-<run号>`），带 5 个机型各自的镜像 + `.manifest` + `.buildinfo`
  + `sha256sums.txt` + 机型对照表。
- **`firmware` 分支**：只保留最近一次，单提交强推，仓库不会膨胀，`main` 不受影响。
- **Actions Artifacts**：保留 30 天。

刷机：

```sh
sysupgrade -n xxx-squashfs-sysupgrade.img.gz      # 已经是本固件
# 原厂首次刷：用 -factory.img.gz，按机型走线刷 / TF 卡刷
```

文件名里的机型段要和机器对上（`hinlink_opc-h68k-a-b` 与 `hinlink_opc-h68k-a-b-usb`
是两台机器，别刷错）。首次进系统 LAN 口 `192.168.100.1`，无密码；5G 模组控制
面板在「网络 → 5G复位」；插件在「服务 → PassWall 2 / Nikki / OpenClash」和
「系统 → 磁盘管理」。

## 本地复现

```sh
git clone --depth 1 https://github.com/immortalwrt/immortalwrt.git
git clone --depth 1 https://github.com/Beaverfffan/immortalwrt-hinlink.git overlay
python3 scripts/inject-hinlink.py --overlay overlay --tree immortalwrt

cd immortalwrt
bash ../diy-part1.sh                    # 要 feed 文件里的相对路径，得在树根跑
./scripts/feeds update -a && ./scripts/feeds install -a
DEVICES="h68k-new" PLUGINS="passwall2 nikki openclash diskman" \
  CONFIG_SEED=../configs/h68k.config bash ../diy-part2.sh
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

## 七个踩过的坑（都已写进脚本，改之前先读）

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

**6. 别把 `openwrt-passwall-packages` 整个 feed 加进来。**
它 19 个包里 18 个与官方 `packages` feed 同名（`xray-core`、`sing-box`、
`chinadns-ng`、`geoview`、`tcping`、`v2ray-geodata` …）。同名 = 同
`PKG_BUILD_DIR` = 并行编译互相踩 —— 之前的 `aic8800` 就是这么炸的
（`ERROR: package/beaverfffan/aic8800 failed to build`，真报错藏在
`logs/package/*/*/compile.txt` 里）。官方那份版本一样新，只缺
`shadowsocksr-libev`，代价是 passwall2 少一个 SSR 协议。

**7. `mihomo` 是虚拟包，不能直接 `=y`。**
`nikki` 的依赖写的是 `+mihomo`，但 `mihomo` 由 `mihomo-meta` / `mihomo-alpha`
两个真包 `PROVIDES` 且互相 `CONFLICTS`。只写 `PACKAGE_nikki=y` 的话依赖判定失败，
`make defconfig` **静默丢弃**这两个包（不报错，只是变成一个 `# … is not set`），
最后编出来的固件里没有 Nikki，也没有任何报错。所以脚本里显式选 `mihomo-meta`
（稳定版，从 Go 源码编；`mihomo-alpha` 是 alpha 分支），defconfig 之后再逐个
回查一遍，缺一个就 fail。

## 用 `-full` 整树编不行吗

行，但那是 Beaverfffan 维护的一棵**完整 immortalwrt 树**（内核、uboot、通用包全是他
fork 那份的），上游一更新就得等他把 rebase 做完。这套流程里官方源码只取 master 的
当次提交，适配层单独更新，两边解耦。
