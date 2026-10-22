# H68K 固件自动编译

用 GitHub Actions 编译 **HinLink H68K** 的 ImmortalWrt 固件，编完推送到
[Zhaoge5766/H68K](https://github.com/Zhaoge5766/H68K)。

## 用的是什么源码

[`Beaverfffan/immortalwrt-hinlink-full`](https://github.com/Beaverfffan/immortalwrt-hinlink-full)
—— 这不是"上游 + 补丁"的两段式仓库，而是一棵**已经把 HinLink 适配固化进去的
完整 immortalwrt 源码树**（基于 immortalwrt master，内核 6.18.55）：

- 16 个机型的设备树、机型定义、板级脚本（`01_leds` / `02_network` / 默认网段）都在里面
- u-boot 侧已经注册好 `U-Boot/hinlink-h68k-rk3568`，并带了 H68K 的 `defconfig`
- `package/beaverfffan/` 下是自维护包（aic8800 无线驱动、OLED、5G 复位、tft-display）
- `configs/<机型>.config` 每机型一份现成 `.config`，`cp` 过去就能 `make`

所以工作流里**没有打补丁这一步** —— 补丁已经在树里了，这是它比
`immortalwrt-hinlink`（只有几十 KB 增量文件、需要跑集成脚本）可靠得多的原因。

## 目录

```
.github/workflows/build-h68k.yml   工作流主文件
tools/upstream-overlay-method/     备选方案：从官方 immortalwrt + 补丁仓库自己合入
```

## 怎么用

1. 把这个仓库的内容推到 `Zhaoge5766/H68K`（或任意你想放编译配置的仓库）。
2. 在 **Settings → Secrets and variables → Actions** 加一个 `PUSH_TOKEN`：
   - classic PAT 勾 `repo`；或
   - fine-grained PAT，对 `Zhaoge5766/H68K` 授予 `Contents: Read and write`。
   - 如果工作流本身就跑在 `Zhaoge5766/H68K` 里，**可以不配**，会自动用内置
     `GITHUB_TOKEN`（工作流已声明 `permissions: contents: write`）。
3. **Actions → Build H68K → Run workflow**。

### 触发方式

| 方式 | 说明 |
| --- | --- |
| 手动 | 可填 `full_ref`（源码分支/标签）、`devices`（只编某几个机型）、`publish`（是否推送） |
| 定时 | 每周六 04:00（北京时间）跟一次上游 |
| push | 改到 `.github/workflows/build-h68k.yml` 时自动跑一次，验证改没改坏 |

### 默认编哪些机型

```
h68k-a-b  h68k-a-b-usb  h68k-c-d-f  h68k-c-d-f-usb  h68k-new
```

对应的设备名分别是 `hinlink_opc-h68k-*`（命名约定：无后缀 = SATA，`-usb` = USB3.0）。
五个机型在**一次编译**里出（共用内核和 rootfs，比一个机型跑一遍快得多）；代价是
rootfs 里会带上其它变体的驱动（比如 a-b 的 BCM43455 固件同时进了 c-d-f 的镜像）——
不影响功能，只是镜像大一点。想要"一机型一份干净 rootfs"就设 `devices` 为单个机型，
跑五次工作流（或用官方 `tools/build_single.sh` 在本地逐个编）。

## 产物在哪

- **Release**：`https://github.com/Zhaoge5766/H68K/releases` —— 每次构建一个
  tag（`h68k-YYYYMMDD-<run号>`），带镜像 + `.manifest` + `.buildinfo` +
  `sha256sums.txt`。这是长期留存的地方。
- **`firmware` 分支**：`https://github.com/Zhaoge5766/H68K/tree/firmware`
  —— 只保留最近一次构建，每次覆盖。这个分支每次都是**单提交强推**，所以仓库不会
  随时间膨胀，`main` 分支也不会被动。
- **Actions 产物**：同一次 run 的 Artifacts，保留 30 天。

刷机：

```sh
# 已经是本固件：升上去（不保留配置）
sysupgrade -n xxx-squashfs-sysupgrade.img.gz

# 原厂固件首次刷：用 -factory.img.gz，按机型走线刷 / TF 卡刷
```

首次进系统 LAN 口是 `192.168.100.1`，无密码；5G 模组控制面板在「网络 → 5G复位」。

## 本地复现（与 CI 等价）

```sh
git clone --depth 1 https://github.com/Beaverfffan/immortalwrt-hinlink-full.git
cd immortalwrt-hinlink-full

./scripts/feeds update -a
./scripts/feeds install -a

# ★ 必做：删掉与 package/beaverfffan/ 同名的 feed 软链
for d in package/beaverfffan/*/; do
  name=$(basename "$d")
  find package/feeds -maxdepth 2 -name "$name" -exec rm -rf {} + 2>/dev/null
done

cp configs/h68k-c-d-f.config .config      # 单机型：改这一行即可换机型
make defconfig
make -j$(nproc) download
make -j$(nproc)
```

产物在 `bin/targets/rockchip/armv8/`。

## 两个容易踩的坑

**1. feeds 同名包会静默覆盖本地包。**
`feeds install -a` 会建出 `package/feeds/packages/fancontrol`、
`package/feeds/luci/luci-app-oled` 这些软链，而 OpenWrt 按字母序扫 `package/`，
`package/feeds/*` 晚于 `package/beaverfffan/*` 加载 ⇒ 同名包被 feed 那份覆盖，
**编译不报错，但装进固件的是上游版**（温控默认关、OLED 界面取 `eth0` 而不是
5G 的 `wwan0`）。工作流里那步「清理与本地包同名的 feed 包」就是干这个的。

**2. 磁盘。**
整棵树的 `build_dir` 能到 10 GB 以上，托管 runner 的 `/` 只有 14 GB 左右。
工作流会先清掉 dotnet / Android SDK / CodeQL 这些预装大件，并且优先把源码树放到
`/mnt`（runner 上一块 70 GB 的独立盘），放不下才退回 workspace。

## 备选方案

`tools/upstream-overlay-method/` 里放的是另一条路：**官方 immortalwrt 源码 +
[`immortalwrt-hinlink`](https://github.com/Beaverfffan/immortalwrt-hinlink) 适配层**，
由 `integrate-hinlink.sh` 在 CI 里现合。适合"上游 -full 仓库没跟上、但想用最新
immortalwrt"的情况。默认工作流不走这条路，原因见
`tools/upstream-overlay-method/README.md`。
