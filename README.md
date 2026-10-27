# kickpi-k1-fnos

为 **KICKPI K1 V1.2（RK3568B2）** 生成可启动的 **飞牛 fnOS ARM64** 固件镜像。

> **📌 移植总指南（下次适配照此走）→ [PORTING.md](PORTING.md)**：全流程清单、
> 十一条坑总表、**网口五层坑的完整修复（DT 复位归属 / PHY 驱动 / vermagic / 加载顺序 / GMAC4 MDC 时钟）**、
> **坑⑦ EEE/LPI（~~2026-10-13 全口关 EEE~~ → 2026-10-17 改判：按官方默认保持开启，不再关闭）**、
> 启动链、验收判据。
>
> **踩坑与修复全记录 → [TROUBLESHOOTING.md](TROUBLESHOOTING.md)**（2026-10-12：
> FIT 哈希被打坏导致刷 eMMC 起不来 / 在线更新后网口全灭 / 静态 PARTUUID 串盘 /
> Windows 读不了 ext4 盘，四条问题的串口原文、取证链、根因、修复与验收判据都在里面）。
> 离线读盘工具在 [`tools/offline-read/`](tools/offline-read/)（免装驱动，需管理员权限）。

方法沿用同一块板子上已验证的 [xck-nas](https://github.com/linyueweia/xck-nas)（LYT T68M）路线：
**飞牛官方通用基镜像 + 本板 DTB + 本板所需树外模块**，**不改动飞牛内核本身**
（飞牛的「文件回收站 / 文件权限管理」等特性依赖官方内核里的 FilesACL 模块，换内核即丢功能；
官方也说明过"新增自己设备的单个 dtb 不影响飞牛的文件系统权限"）。

## 为什么 K1 需要额外工作

K1 的双千兆网口用的是 **Maxio MAE0621A** PHY（PHY ID `0x7b744411`）。
**主线内核至今没有该驱动**（2026-07 才投 LKML，未进稳定版），
飞牛 6.18 内核的 104 个 PHY 驱动里也没有它 —— 这正是此前适配失败的原因。

好消息（已实测确认）：

| 检查 | 结果 |
|------|------|
| 飞牛内核模块签名 | **完全未启用**（无 `CONFIG_MODULE_SIG*`、无 lockdown）→ 自编模块可加载 |
| 树外编模块基础 | 官方 header 包含完整内核树（`Makefile`/`Module.symvers`/`include`/`scripts`/`arch/arm64`）|
| 实测 | `maxio.c` 对飞牛内核编译通过；**目标 release 必须从基镜像取**（当前基镜像 v1.1.0 = `6.18.18.c1145-trim`，社区包 `6.18.18-trim` 差一个后缀即被拒）|
| vermagic 硬闸 | `build-modules.sh` 逐 `.ko` 比较含 `KREL`，不符即 `exit 1`；`modules.dep` 用宿主 `depmod -b` 生成并断言 |

## 仓库内容

```
dts/rk3568-kickpi-k1.dts        板级设备树源（自包含展开式，无 #include；媒体簇对标官方 R5S）
dts/r5s-media-allowlist.txt     媒体簇对标例外清单（每条例外都要写理由/证据）
dist/rk3568-kickpi-k1.dtb       预编译 DTB（由 CI「只编 DTB」工作流在飞牛内核树里现编回提交）
dist/rk3568-nanopi-r5s-official.dtb  官方 R5S 参照件（媒体簇对标基准，勿改）

modules/src/{maxio.c,BUILD-RECIPE.md,WIFI-SRC-ORIGIN.txt}   Maxio PHY 驱动源 + 构建配方 + WiFi 源码来源说明
modules/wifi-src.tar.gz         SWT6621S 整棵源码（已打 patches/ 的 6.18 补丁；装配时随镜像下发）
modules/firmware/               SWT6621S 固件 15 个（取自实机原厂系统，装配时强制双路径注入）
modules/ota/                    **唯一**模块自愈实现（modules-ensure.sh + systemd 单元）
（.ko 不入库：一律由 build-modules.sh 对基镜像 header 现编，vermagic 才能对上）
patches/wifi-6.18-port.patch    驱动移植补丁（12 文件 +64/-41，可干净应用到原始源码）

uboot/k1-ki-first32m.bin        K1 引导件（lyw-ki 仓 iStoreOS 构建的 U-Boot 2025.10，
                                注入载荷区 [17408,32MiB)，fdt_fixup_memory + mmc 优先）
build-k1-fnos.sh                镜像装配（走官方 boot.scr：part uuid 现场取分区身份，不写死 UUID）
build-dtb.sh                    在飞牛内核树里编 DTB + SoC 一致性门禁
build-modules.sh                按基镜像 header 现编四个树外模块（vermagic 硬闸）
tools/r5s-media-parity.py       媒体簇 vs 官方 R5S 逐节点对标门禁（纯 Python，无 dtc 依赖）
tools/fit-resign.py             FIT 哈希校验/重签（改写 FIT 内负载后必跑，否则 SPL 拒载）
tools/verify-repo-static.sh     仓库静态门禁（eMMC 劫持 / EEE / DTB 同步 / 媒体簇对标 / 文档可执行位）
tools/offline-read/             离线读盘（Windows 免装驱动）：ext4 列举/提取、btrfs 列举/提取
TROUBLESHOOTING.md              故障复盘：串口原文、取证链、根因、修复、验收判据
docs/OTA-验收单.md              在线升级后的 P1/P2/P3 验收清单
docs/REPO-MAP.md                **仓库导览**：每个文件一行说明 + 被谁消费 + 能不能改
verify-fnos-bootchain.sh        引导链六环验证（含 CMA/kernelfile/OTA 自愈产物的硬断言）
tools/tests/kf-boot-gate-test.sh 引导参数硬门禁单元测试（9 例，构建前秒级）
```

## 双千兆网口：取证结论与修复（2026-10）

四路只读取证（内核驱动普查 / DT 三线对拍 / 装配注入链 / git·CI·实机日志史）得出的根因，
**四条互相独立、任一条都足以让网口起不来**：

| # | 根因 | 证据 | 修复 |
|---|------|------|------|
| 1 | **复位被两个节点持有**（PHY 节点 `reset-gpios` + MAC 侧 `snps,reset-gpio` 三件套）→ 6.18 里第二次 `gpiod_request()` 返 `-EBUSY` → `Cannot register the MDIO bus` → GMAC probe 失败 | 实机日志 `-EBUSY` ×16、`probe … failed with error -16`（相位A）；commit `24b1db5` 的正则错位还把属性写进了 `rx-queues-config/queue0` | `dts/rk3568-kickpi-k1.dts` 删 PHY 侧与 queue0 的复位，**只留 MAC 侧**三件套（L1 实机 / L2 官方6.1 / L3 官方5.10 三线一致）；dts 手维护成品，生成期一次性工具（原 tools/dts-pipeline、merge-dtb.py）已按“跟官方原生走”原则删除 |
| 2 | **内核里没有 0x7b744411 的 PHY 驱动**（2877 个模块 163 条 mdio 别名 0 命中；MAC 驱动 stmmac/dwmac-rk 反而齐全） | `a1-kernel-drivers.json` | `maxio.ko` 外挂是唯一路径；装配期注入 `updates/kickpi-k1/` |
| 3 | **`maxio.ko` vermagic 对不上**（预编件 `6.18.18-trim` vs 基镜像 `6.18.18.c951-trim`；且 `CONFIG_MODULE_SIG/MODVERSIONS` 未开 → 逐字比较必拒） | 实机 `modinfo: ERROR: Module maxio not found.`；`modules.dep` 无 `updates/*` | 删掉预编 `.ko`；`build-modules.sh` 对基镜像 header 现编 + vermagic 硬闸；**`depmod` 条件恒假从未跑过** → 改用宿主 `depmod -b` 并断言 `modules.dep` 含 `maxio.ko` |
| 4 | **加载顺序无保障**：`dwmac_rk.ko` 由 udev 冷插拔 10s 拉起，`kickpi-k1-modules.service` 11.19s 才跑 → `phy_attach_direct()` 先绑 Generic PHY，晚到的 maxio 被跳过 | driver-core 分析 + 实机时间轴 | `etc/modprobe.d` 写 `softdep dwmac_rk pre: maxio`；insmod 单元不再 `2>/dev/null` 吞错 |
| 5 | **`phy_id` 被读成 `0xffff4411` 而非 `0x7b744411`** → maxio（mask `0x7fffffff`）永远匹配不上 → 绑 Generic PHY → 写不了 Maxio 私有页（page `0xd8f~0xda5`）→ MAC 报 `Failed to reset the dma` / `DMA engine initialization failed` | **8 份真机启动日志**：有 PHY 的 3 次全部 `phy_id=0xffff4411`、`MAE0621A` 命中 0/8、`Link is Up` 0/8；根因是 `stmmac_mdio_reset()` 里那条"复位后补一个 MDC 时钟"的 dummy read 被 `if (core_type != DWMAC_CORE_GMAC4)` 跳过，而 **RK3568 正是 GMAC4**（驱动注释自认 "To be updated for GMAC4 if needed"）→ `snps,reset-gpio` 释放后 MDC 全程静止 → PHY 复位不完成 → of_mdio 扫描第一帧(PHYID1) 读回全 1 | ① **根治**：两个 `mdio` 节点在 `phy@0` **之前**插占位 `ethernet-phy@1`，让那一帧先发生、产生 MDC 时钟，随后 `phy@0` 即读到正确 ID（`of_mdio.c` 对 `-ENODEV` 只打 `missing` 不中断注册；`phy_device.c` 的 `(id & 0x1fffffff) == 0x1fffffff → -ENODEV` 已核实）② **保险**：maxio id 表补 `{0xffff4411, 0xffffffff}` ③ 补回 `local-mac-address`（原为随机 MAC） |

装配期新增的对应硬门禁：`depmod -b` + `modules.dep` 断言、固件强制 15 个、`softdep` 断言、
`EXPECT_MODULES=4`、网口 DT 门禁 `tools/verify-k1-net-dts.sh`（单持有 / parents 2 组 /
PHY 与 queue0 干净 / 无 `realtek,` / 四延迟），以及仓库静态门禁 `tools/verify-repo-static.sh`。
用户态侧：禁用残留的 `networking.service`(ifupdown，本镜像由 NM 管网)。
**rga3 已放回开机清单（2026-10-27 实机翻案）**：旧版本摘掉它的理由是「8 次开机 `Bad address`(EFAULT)」，
实机复核证明那是**旧 DTB** 的问题（缺 `rk_rga@fdeb0000` 节点 / `rga@fdeb0000` reg 段不对 → `rga_iommu_bind`
失败）；DTB 对齐官方 R5S 之后（sha256 `9ab5b742…`）开机自动加载成功：
`rga2 fdeb0000.rk_rga: probe successfully, hw_version:3.2.63318` + `rga_iommu: IOMMU binding successfully`
+ `rga: Module initialized. v1.3.4`，`/dev/rga` 出现、`systemd-modules-load` active、零 EFAULT。
摘掉 rga3 = 整机没有 RGA 硬件加速，已被构建门禁反向钉死（必须含 rga3/rknpu/rk_vcodec）。
（`rga3.ko` 确实没有任何 `MODULE_DEVICE_TABLE` 别名，所以必须靠 modules-load.d 显式加载。）

**坑⑦（2026-10-13 追加，2026-10-17 改判）——EEE 省电态**：当年按"整口 Link Down（高峰 34 次/3h、
深夜不掉、两端 CRC=0）+ 对端 `phy_eee_wakeup_error_n=8126`"判为 EEE/LPI 唤醒时序问题，
装了脚本 + 开机服务 + NM dispatcher 三层关闭件。

**2026-10-17 在 T68M 主路由上按日志复核推翻**：EEE 本来就处于关闭态时掉线照样发生；141 次 Link Down
每一次都伴随对端 1–5 s 内重新 DHCP（对端在重启），且 20 s 空档不符合本端自协商时长。
⇒ 本仓**不再关 EEE**：镜像里不得出现 `kickpi-k1-eee-off.sh` / 服务 / dispatcher（CI 反向门禁），
存量系统用 `assets/fnos-fix-log-errors.sh` 会把历史三层件清掉。若将来真抓到 `phy_eee_wakeup_error_n`
增长并伴随掉线，走 DT 的 `eee-broken-1000t`（唯一有内核依据的关法）。历史取证见
[TROUBLESHOOTING.md §6b](TROUBLESHOOTING.md)。
**验收只看具名日志门**（`modules/src/BUILD-RECIPE.md` 底部）：0 × MDIO 注册失败、0 × probe 失败、
`end0/end1` 驱动 `rk_gmac-dwmac`、`phy_id=0x7b744411`、0 × `Failed to reset the dma`、`Link is Up`。

## 引导链（重点，因为本机是安卓布局）

K1 的 eMMC 是 **Rockchip 安卓式 GPT**（p1 uboot / p2 misc / p3 boot / p4 recovery / p5 backup / p6 rootfs），
**不是** Linux 的 BOOT+rootfs 布局。因此：

1. 本仓库产出的是**自包含的 Linux 布局镜像**，刷到 **SD 卡**，由镜像前导区的 U-Boot
   （`uboot/k1-ki-first32m.bin`，来自 lyw-ki 仓的 K1 iStoreOS 构建：U-Boot 2025.10-OpenWrt
   + `ddr-v1.23-03ea844c5d`，与本板 eMMC 原厂同版本；`boot_targets` 本就 mmc 优先）
   从本介质引导 —— **全程不写 eMMC**，正在运行的厂商系统不受影响。
2. 必须防守三条安卓布局侧路（`verify-fnos-bootchain.sh` 里是硬闸）：
   - u-boot 若带 `bootrkp`/`boot_android` 且先扫到 eMMC 的 `boot` 分区 → 会去启厂商安卓系统
   - 引导配置里 `root=` 若指向 `/dev/mmcblk0*` 或厂商 PARTUUID → 会挂到 eMMC 上的厂商根分区
   - BROM 冷启动若优先 eMMC → 压根不从 SD 起（厂商 env 显示 `rkimg_bootdev` 先探 SD）
3. `idbloader` 内嵌板级 DDR 初始化固件，跨板复用会 DDR 训练不匹配（实测 T68M 那份是
   `DDR V1.18`，与本板 LPDDR4@1560MHz 不符）—— 只能用为 K1 编译的那一对；装配期断言拒绝
   V1.18 与 1056MHz 家族，要求 `v1.23`。

## 媒体簇与引导参数对标官方 R5S（2026-10-27 定案）

用户口径：**K1 与官方 R5S 同 SoC，媒体簇与 CMA 都与官方 R5S 方案对齐，不自创**。

- 参照件 = `dist/rk3568-nanopi-r5s-official.dtb`（飞牛官方 R5S 固件里那份，
  sha256 `95d4f336…`，与 xck-nas 仓同一份）
- 门禁 = `tools/r5s-media-parity.py`：GPU/NPU/VPU/RGA/JPEGD/IEP/mpp-srv/IOMMU/OPP 共 26 个节点，
  逐属性比对；phandle 引用解析成**目标节点名**再比（两板编号不同、指向相同即一致）。
  本板有实机证据的差异写进 `dts/r5s-media-allowlist.txt`，一条一理由。
- 本轮对齐到位的项：GPU `interrupts/interrupt-names` 顺序（gpu,mmu,job）、GPU opp 表节点名
  `opp-table-1`、NPU opp 表补 `rockchip,init-freq=<900MHz>`、`vepu@fdee0000` 节点名、
  `rga@fdeb0000` 的 `reg=0x180` + `clock-names=aclk/hclk/sclk`、新增 `rk_rga@fdeb0000`(rockchip,rga2)、
  三个 IOMMU 补 `interrupt-names`（vdpu_mmu/vepu_mmu/rkvdec_mmu）。
- 一条**故意不齐**（已登记 allowlist，附实机证据）：`vdpu@fdea0400`（与在用 legacy 解码节点寄存器
  重叠，新增会让同一硬件被两个 mpp 客户端争用 —— 就是 10-19 转码死机那一类风险，需先上机验证）。
  ~~`iommu@fde4b000` 保持 disabled~~ **2026-10-27 已撤销、改回官方 `okay`**：实机 iommu 正常 probe
  （`/sys/class/iommu/fde4b000.iommu`、`iommu_group/8`），dmesg `rknpu iommu is enabled, using iommu mode`，
  NPU 中断 0→1428、零分配失败。冷启动仍会打一次 ack 超时，但 genpd `Forcing sync_state()` 后 iommu 就起来了
  —— 旧结论「DT 侧无法根治」已过期。详见 `TROUBLESHOOTING.md` §2.3。
- **CMA = 256M**（官方 R5S 的 `fnEnv.txt` 就是 `extraargs=cma=256M`；官方 DTB 无 reserved CMA 区，
  cmdline 的 `cma=` 是唯一决定因素）。构建期硬断言 `extraargs` 必须含 `cma=256M`，镜像门禁再断言一次
  并反向拒绝 1G/2G。历史 1G 只是绕开相册 AI 的 339MB 连续申请，**不再使用**。

## 引导链走官方 boot.scr（2026-10-12 改：UUID 不写死）

- 官方基镜像 BOOT 分区里只有 `boot.cmd` / `boot.scr` / `fnEnv.txt` / `grub`，**没有 extlinux**；
  `boot.cmd` 每次启动 `part uuid` 现场取 bootuuid/rootuuid 再拼进 bootargs
  → 分区身份永不写死，TF 卡与 eMMC 双介质并存也不会串盘。
- `kernelfile` 由基镜像给定（v1.1.0 = `vmlinuz-6.18.18.c1145-trim`），官方
  `/etc/kernel/postinst.d/15-update-ukernel-ver` 每次装新内核都会改写它。装配期三道硬门禁：
  目标**存在**、**>5MB**、内容是 **arm64 Image 或 gzip**；指向的文件不存在时自动改成本板唯一的
  `vmlinuz-*`，一个都没有则构建失败（"fnEnv 指到不存在的内核 → 刷进去必黑无输出"是真实事故）。
- 本仓库原先自造 `extlinux/extlinux.conf`（静态 `root=PARTUUID=` 构建期读到的值），而 u-boot 优先走
  extlinux → 身份被钉死；更麻烦的是该值继承自官方基镜像，**所有产物完全相同**（实测 TF 卡与
  KICKPI-K1_34.img 都是 `e1b4e4d7-a003-4448-ade5-273ed910c9ad`）。
- 现改为：不生成 `extlinux.conf`，K1 参数（cma / loglevel）写进官方 `fnEnv.txt` 的 `extraargs`；
  构建期硬断言：`boot.cmd` 必须含 `part uuid`、且 `extlinux/extlinux.conf` 必须不存在。
- 回退旧内核：改 `fnEnv.txt` 的 `kernelfile=/vmlinuz-<旧内核>`（官方键，boot.cmd 认）。
  ⚠ 官方 `/etc/kernel/postinst.d/15-update-ukernel-ver` 每装一个新内核都会把它改回新内核，
  手工回退只在下次内核更新前有效（2026-10-12 实测：更新后 `kernelfile` 被写成
  `vmlinuz-6.18.18.c1145-trim`）。我们的 `zz-kickpi-k1-modules` 正是利用这一点：
  官方先把引导指向新内核（`15-`），我们再对同一内核编好 maxio（`zz-`），顺序不可颠倒。
  硬回退材料留在 `extlinux/extlinux.conf.k1-static`（改回 `extlinux.conf` 即切静态链路）。
- ✅ **已实测跑通**（2026-10-12，CI `4b9d1c5` 镜像整机启动 + 在线更新）：
  实机 `cmdline` 里 `ubootpart=PARTUUID=425c93b1-5f56-4d3e-90a2-7cbaa3353337`
  正是 `part uuid` 现场取的 boot 分区身份（与基镜像 BOOT PartGUID `b1935c42-…` 字节序互逆），
  `root=PARTUUID` + `extraargs` 均按预期拼进；`/boot/extlinux/` 下只剩不被 u-boot 识别的
  `extlinux.conf.k1-static`，确认引导确实走官方 boot.scr。

## 用法

```bash
# 1) 按基镜像 header 现编 4 个模块（maxio + SWT6621S 三件套；vermagic 硬闸）
./build-modules.sh <基镜像> built-modules

# 2) 在飞牛内核树里编 DTB（本机没有 dtc 也可以只走 CI 的「只编 DTB」工作流）
./build-dtb.sh

# 3) 装配镜像（注入本板 U-Boot 载荷 + DTB + 模块 + depmod + 固件 + softdep + OTA 自愈素材）
BASE=path/to/fnnas-official-arm64-image_rockchip.img \
DTB=dist/rk3568-kickpi-k1.dtb \
UBOOT=uboot/k1-ki-first32m.bin \
MODULES_DIR=built-modules \
./build-k1-fnos.sh

# 4) 仓库静态门禁（eMMC 劫持 / EEE 反向 / DTB 与 dts 一致 / 媒体簇对标官方 R5S / 文档可执行位）
bash tools/verify-repo-static.sh

# 5) 六环验证（含 CMA=256M、kernelfile 形态、OTA 自愈产物、modules.dep/softdep/固件/EXPECT_MODULES）
EXPECT_MODULES=4 ./verify-fnos-bootchain.sh out/*.img

# 6) 刷 SD 卡（用户执行；写前先认盘：K1 的 eMMC 是 mmcblk0，TF 卡是 mmcblk1，别写反）
lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT          # 期望：mmcblk1 ≈14.7G、无挂载点
sudo xz -dc out/*.img.xz | sudo dd of=/dev/mmcblk1 bs=4M conv=fsync status=progress
```

## 已知限制（如实记录）

- **CMA 固定 256M（官方 R5S 口径）**，且**够用**——前提是 NPU 走 iommu 模式（2026-10-27 起默认）：
  iommu 模式下 rknpu 的 GEM 走 scatter-gather 从系统内存分配，不受 CMA 尺寸约束；
  non-iommu 逃生门则必须物理连续，fnOS `trim.face_det` 单次 339MiB 会必失败（`cma: alloc failed -16`），
  并可能把内核挂死（靠看门狗 44s 硬复位）。**所以「相册 AI 要不要放大 CMA」这个老问题已经被
  「iommu 模式」从根上解决**：不要为了 339MB 去放大 CMA，那会挤压 VPU 编解码共用的 CMA。
- **媒体簇与官方 R5S 只剩一处不同**（见 `dts/r5s-media-allowlist.txt`，附实机证据）：
  不新增 `vdpu@fdea0400`（与在用 legacy 解码节点寄存器重叠）。`iommu@fde4b000` 已于 2026-10-27
  改回官方 `okay`（iommu 模式，NPU 走 scatter-gather）。
- **摄像头 gc5035**：飞牛 6.18 骨架没有 MIPI-CSI/rkisp 基础设施，强行导入会把 5.10 厂商 CSI 节点
  （含错乱引用）带进来，故剔除 —— 本产物下摄像头大概率无法工作。
- **HDMI/VOP**：保留骨架（6.18）值，K1 特有板级参数未覆盖，需上机确认。
- **SATA**：实机只有 `sata@fc000000` 是 enabled，另两个节点为 disabled（已按实机保留）。
- **WiFi MAC**：驱动移植时关闭了 Rockchip vendor storage 取 MAC 的路径（内核无该导出符号），
  改用芯片 MAC 或随机地址；如需固定 MAC 需另寻途径。
- 所有 .ko 均只完成**编译与静态符号校验**（vermagic 匹配、未定义符号全部命中内核符号表），
  **尚未在真机 insmod/组网实测**。
- **本轮（2026-10-27）改动只到「CI 产物自证」层**：媒体簇对齐后的 DTB 未上机跑过硬解/转码，
  上线前按 `docs/OTA-验收单.md` 与 README「验收判据」在实机复核。


---

## 刷写完必做：GPT 按目标盘适配（否则卡在 `Waiting for root device`）

镜像只写到盘的头部，GPT 主头里的 `alternate_lba` / `last_usable` 仍指向**镜像文件末尾**。
刷进比镜像大的卡（几乎所有 TF/SD 卡）后：

- **U-Boot 宽容**：照样从 `mmcblk1:1` 读 `boot.scr`，引导看起来完全正常；
- **Linux 内核严格**：`alternate_lba` 不在设备末尾就拒绝整张分区表 → `mmcblk1:` 后面
  **不列 p1 p2** → 卡死 `Waiting for root device PARTUUID=...`（无 panic、无报错、干等）。

**刷完对目标盘跑一次**（三仓通用同一份工具）：

```sh
# 1) 按目标盘真实容量重算 GPT 全部字段（主/备头 + 分区项 + 保护 MBR），并把 rootfs 的 PARTUUID 换新
python3 tools/gpt-fix.py /dev/sdX --apply --renew-partuuid=2

# 2) 判据
fdisk -l /dev/sdX                    # 必须能看到 p1 / p2
python3 tools/gpt-fix.py /dev/sdX    # 必须输出「GPT 全字段自洽（主/备/MBR）」
```

`--renew-partuuid=2` 的作用：本仓镜像与板上 eMMC 里的系统同源时 `rootfs` 的 PARTUUID 相同，
内核会**先挂到 eMMC 那个**（起的是旧系统而不是卡上的）。换掉 GUID 即可，
`boot.cmd` 用 `part uuid` 现场取值，**不需要改任何引导文件**。

构建期已有同一道门禁（装配末尾 `gpt-fix.py --apply`），保证**镜像自身**自洽；
上面这一步是**设备侧**适配，两者都要跑。

> 2026-10-27 实机两次踩坑：T68M 与 K1 都表现为「U-Boot 正常、内核干等根设备」，
> 日志特征 = `mmcblk1: mmc1:… 14.7 GiB` 之后**没有** `mmcblk1: p1 p2` 这一行。
