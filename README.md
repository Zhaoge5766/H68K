# H68K 固件（全系）

由 GitHub Actions 自动构建：官方 ImmortalWrt + HinLink 适配层
（[Beaverfffan/immortalwrt-hinlink](https://github.com/Beaverfffan/immortalwrt-hinlink)）。

机型：h68k-a-b / a-b-usb / c-d-f / c-d-f-usb / new
插件：PassWall 2 / Nikki / OpenClash / DiskMan（三个代理同时只开一个）

历次产物在 [Releases](https://github.com/Zhaoge5766/H68K/releases) 里。

本分支 `firmware` 只保留**最近一次**构建，每次覆盖。

| 项 | 值 |
| --- | --- |
| 构建时间 | 2026-10-24 01:24 UTC |
| run | #11 |

刷机：`sysupgrade -n *.img.gz`；原厂首次刷用 `-factory.img.gz`。
首次进系统 LAN 口 `192.168.100.1`，无密码。
