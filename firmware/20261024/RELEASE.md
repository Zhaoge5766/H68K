## HinLink H68K 全系 · ImmortalWrt

| 项 | 值 |
| --- | --- |
| 构建时间 | 2026-10-23 22:45 UTC |
| 官方源码 | immortalwrt `e695009` |
| 适配层 | immortalwrt-hinlink `38a2442` |
| 机型 | h68k-a-b h68k-a-b-usb h68k-c-d-f h68k-c-d-f-usb h68k-new |
| 插件 | passwall2 nikki openclash diskman |
| run | #11 |

### 产物
```
RELEASE.md
immortalwrt-rockchip-armv8-hinlink_opc-h68k-a-b-ext4-sysupgrade.img.gz
immortalwrt-rockchip-armv8-hinlink_opc-h68k-a-b-squashfs-sysupgrade.img.gz
immortalwrt-rockchip-armv8-hinlink_opc-h68k-a-b-usb-ext4-sysupgrade.img.gz
immortalwrt-rockchip-armv8-hinlink_opc-h68k-a-b-usb-squashfs-sysupgrade.img.gz
immortalwrt-rockchip-armv8-hinlink_opc-h68k-c-d-f-ext4-sysupgrade.img.gz
immortalwrt-rockchip-armv8-hinlink_opc-h68k-c-d-f-squashfs-sysupgrade.img.gz
immortalwrt-rockchip-armv8-hinlink_opc-h68k-c-d-f-usb-ext4-sysupgrade.img.gz
immortalwrt-rockchip-armv8-hinlink_opc-h68k-c-d-f-usb-squashfs-sysupgrade.img.gz
immortalwrt-rockchip-armv8-hinlink_opc-h68k-new-ext4-sysupgrade.img.gz
immortalwrt-rockchip-armv8-hinlink_opc-h68k-new-squashfs-sysupgrade.img.gz
profiles.json
sha256sums.txt
```

### 机型对照

| 文件名里的机型 | 机器 |
| --- | --- |
| `hinlink_opc-h68k-a-b` | A/B 板（2022，双千兆 2 口）+ SATA |
| `hinlink_opc-h68k-a-b-usb` | A/B 板，USB3.0（SATA 与 USB3.0 二选一） |
| `hinlink_opc-h68k-c-d-f` | C/D/F 板（2022~2023.4，四网口）+ SATA |
| `hinlink_opc-h68k-c-d-f-usb` | C/D/F 板，USB3.0 |
| `hinlink_opc-h68k-new` | 新机器（2023 末~2024，SATA + USB3.0 可同时用） |

刷机：
- 已在同款固件上：`sysupgrade -n xxx-squashfs-sysupgrade.img.gz`（LuCI 里直接升级也行）
- 原厂固件首次刷：用 `-factory.img.gz`，按机型走线刷 / TF 卡刷
- 首次进系统：LAN 口 `192.168.100.1`，无密码

插件入口（LuCI）：服务 → PassWall 2 / Nikki / OpenClash；系统 → 磁盘管理。
OpenClash 与 PassWall 2 / Nikki 都会接管 DNS 与 nftables，**同时只开一个**。
