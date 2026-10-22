# 备选方案：官方 immortalwrt + 适配层仓库

默认工作流**不走这条**，用的是 `Beaverfffan/immortalwrt-hinlink-full`
（一棵已固化的完整源码树）。这里保留的是原始思路：拉官方 immortalwrt，
再把 [`Beaverfffan/immortalwrt-hinlink`](https://github.com/Beaverfffan/immortalwrt-hinlink)
的增量文件合进去。

什么时候用：上游 `-full` 仓库还没跟上，但你想拿最新 immortalwrt。

## 为什么默认不用它

- `/immortalwrt-hinlink` 只有几十 KB 增量文件，合入靠脚本，脚本对上游结构有假设
  （官方 `01_leds`/`02_network` 的 `case` 块数量一变，它自带的 `integrate.py`
  就直接 skip，固件里没有网络和 LED 配置）；
- 适配层是按某个 immortalwrt 提交写的，DTS/补丁与最新上游可能对不上，
  失败点分散在"合入→defconfig→内核→镜像"四个阶段；
- `-full` 仓库已经把这些都验证过一遍了，而且给每个机型配了现成 `.config`。

## 文件

| 文件 | 作用 |
| --- | --- |
| `integrate-hinlink.sh` | 把适配层合入 immortalwrt 树（已针对 master 实测可跑通） |
| `filter-devices.py` | 按白名单裁剪机型定义 |
| `prune-device-packages.py` | 剔掉当前源码树里不存在的包名 |
| `h68k.config` | 多机型 `.config` 起点（H68K 五个变体一次编） |

## 用法

```sh
git clone --depth 1 https://github.com/immortalwrt/immortalwrt.git
git clone --depth 1 https://github.com/Beaverfffan/immortalwrt-hinlink.git

(cd immortalwrt && ./scripts/feeds update -a && ./scripts/feeds install -a)

bash integrate-hinlink.sh "$PWD/immortalwrt" "$PWD/immortalwrt-hinlink"

cd immortalwrt
cp ../h68k.config .config
make defconfig
python3 ../prune-device-packages.py target/linux/rockchip/image/armv8.mk.hinlink tmp/.packageinfo
make defconfig
make -j$(nproc) download && make -j$(nproc)
```

## 合入时做的几个判断（都有实测依据）

1. **板级脚本用独立文件，不插官方 `case` 块。**
   适配层的 `01_leds` / `02_network` 自带 `board_config_update` / `flush` / `exit 0`，
   是完整可执行脚本，装成 `03_hinlink_leds` / `04_hinlink_network` /
   `05_hinlink_lan_ip` 即可按字典序排在官方 `02_network` 之后执行；
   官方对未知 board 的兜底是空操作，互不干扰。插 case 块的方案太脆。

2. **机型定义按白名单裁。**
   OpenWrt 把 `define Device/xxx` 原样变成 kconfig 符号，而适配层里 H29K 的机型名
   带小数点（`hinlink_h29k-v1.3-1.14_rk3528`），kconfig 符号里出现 `.` 会让
   `make defconfig` 直接语法报错 —— 跟编哪个机型无关，是整个 target 生成不出来。
   只想编 H68K 就更没必要带上另外 11 个机型。

3. **`armv8.mk.hinlink` 是"追加内容"而不是 `include`。**
   适配层的 `integrate.py` 用 `include ./armv8.mk.hinlink`，但 make 的 `include`
   相对**当前工作目录**而不是相对 makefile 所在目录，取决于调用方式；
   直接追加最稳。

4. **U-Boot 变体按"插到 `BuildPackage/U-Boot` 之前"注册。**
   `u-boot.mk` 展开时才枚举 `U-Boot/*` 变量，插在 `$(eval $(call BuildPackage/U-Boot))`
   之后就晚了。适配层的 `0001-*.patch` 是按上下文打的，上游 Makefile 一挪就废；
   这里改成定位调用点插入，只有一个前提：`U-Boot/rk3568/Default` 存在。

5. **内核补丁默认不合。**
   `patches/*.patch` 是 fbcon 光标 / fbtft gc9307 / fbtft 偏移，全给 H29K、H89K 的
   屏用的，H68K 没有屏。默认跳过（`APPLY_KERNEL_PATCHES=1` 可打开）。

## 已知的未验证项

- 内核补丁那几个 patch 是按某个内核版本写的，`APPLY_KERNEL_PATCHES=1` 时不保证能打上；
- `fancontrol` / `luci-app-fancontrol` 默认不合入（与官方 feed 同名，同名包会静默
  互相覆盖）；H68K 用不到，编 H69K/H88K/H89K 时才需要，届时设
  `LOCAL_PKG_EXCLUDE=""`。
