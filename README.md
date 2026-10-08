# kickpi-k1-fnos

为 **KICKPI K1 V1.2（RK3568B2）** 生成可启动的 **飞牛 fnOS ARM64** 固件镜像。

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
| 实测 | `maxio.c` 对飞牛内核编译通过；**目标 release 必须取自基镜像**（`6.18.18.c951-trim`），社区包 `6.18.18-trim` 差一个后缀即被拒 |
| vermagic 硬闸 | `build-modules.sh` 第 5 步逐个 `.ko` 比对含 `KREL`，不符即 `exit 1` |

## 仓库内容

```
dts/rk3568-kickpi-k1.dts        板级设备树源（自包含展开式，无 #include）
dist/rk3568-kickpi-k1.dtb       预编译 DTB（sha256 c53d9896…）
tools/merge-dtb.py              可复现的合并脚本（飞牛 6.18 原生 R5S 骨架 + K1 板级覆盖，幂等）

modules/src/{maxio.c,BUILD-RECIPE.md}   Maxio PHY 驱动源 + 构建配方
modules/swt6621s/               SWT6621S WiFi/BT 三模块的树外源（补丁见 patches/）
modules/firmware/               SWT6621S 固件 15 个（取自实机原厂系统，装配时强制注入）
（.ko 不入库：一律由 build-modules.sh 对基镜像 header 现编，vermagic 才能对上
  6.18.18.c951-trim；曾提交的预编 .ko 是 6.18.18-trim 社区包产物，装机必被拒）
patches/wifi-6.18-port.patch    驱动移植补丁（12 文件 +64/-41，可干净应用到原始源码）

uboot/rk3568/kickpi-k1/         引导配置 + DDR 决策记录（含实测证据）
build-k1-fnos.sh                镜像装配（root= 自动取镜像自身 PARTUUID，绝不写设备）
verify-fnos-bootchain.sh        引导链六环验证
fetch-uboot-from-kk.sh          从 kk(iNextOS) 构建产物取本板 u-boot 对（含 DDR 防呆）
```

## 双千兆网口：取证结论与修复（2026-10）

四路只读取证（内核驱动普查 / DT 三线对拍 / 装配注入链 / git·CI·实机日志史）得出的根因，
**四条互相独立、任一条都足以让网口起不来**：

| # | 根因 | 证据 | 修复 |
|---|------|------|------|
| 1 | **复位被两个节点持有**（PHY 节点 `reset-gpios` + MAC 侧 `snps,reset-gpio` 三件套）→ 6.18 里第二次 `gpiod_request()` 返 `-EBUSY` → `Cannot register the MDIO bus` → GMAC probe 失败 | 实机日志 `-EBUSY` ×16、`probe … failed with error -16`（相位A）；commit `24b1db5` 的正则错位还把属性写进了 `rx-queues-config/queue0` | `dts/rk3568-kickpi-k1.dts` 删 PHY 侧与 queue0 的复位，**只留 MAC 侧**三件套（L1 实机 / L2 官方6.1 / L3 官方5.10 三线一致）；`tools/dts-pipeline/fix-phy-reset.py` 改为「只删不断言」→ 现在会清理并补齐 MAC 侧，违规 `exit 1` |
| 2 | **内核里没有 0x7b744411 的 PHY 驱动**（2877 个模块 163 条 mdio 别名 0 命中；MAC 驱动 stmmac/dwmac-rk 反而齐全） | `a1-kernel-drivers.json` | `maxio.ko` 外挂是唯一路径；装配期注入 `updates/kickpi-k1/` |
| 3 | **`maxio.ko` vermagic 对不上**（预编件 `6.18.18-trim` vs 基镜像 `6.18.18.c951-trim`；且 `CONFIG_MODULE_SIG/MODVERSIONS` 未开 → 逐字比较必拒） | 实机 `modinfo: ERROR: Module maxio not found.`；`modules.dep` 无 `updates/*` | 删掉预编 `.ko`；`build-modules.sh` 对基镜像 header 现编 + vermagic 硬闸；**`depmod` 条件恒假从未跑过** → 改用宿主 `depmod -b` 并断言 `modules.dep` 含 `maxio.ko` |
| 4 | **加载顺序无保障**：`dwmac_rk.ko` 由 udev 冷插拔 10s 拉起，`kickpi-k1-modules.service` 11.19s 才跑 → `phy_attach_direct()` 先绑 Generic PHY，晚到的 maxio 被跳过 | driver-core 分析 + 实机时间轴 | `etc/modprobe.d` 写 `softdep dwmac_rk pre: maxio`；insmod 单元不再 `2>/dev/null` 吞错 |

装配期新增的对应硬门禁：`depmod -b` + `modules.dep` 断言、固件强制 15 个、`softdep` 断言、
`EXPECT_MODULES=4`、网口 DT 门禁 `tools/verify-k1-net-dts.sh`（单持有 / parents 2 组 /
PHY 与 queue0 干净 / 无 `realtek,` / 四延迟），以及仓库静态门禁 `tools/verify-repo-static.sh`。
用户态侧：禁用残留的 `networking.service`(ifupdown，本镜像由 NM 管网)、
摘掉每开机 `Bad address` 的 `rga3`（有 OF 表，仍由 udev 别名加载），保证 `systemd-modules-load` 不再开机失败。

**验收只看具名日志门**（`modules/src/BUILD-RECIPE.md` 底部）：0 × MDIO 注册失败、0 × probe 失败、
`end0/end1` 驱动 `rk_gmac-dwmac`、`phy_id=0x7b744411`、0 × `Failed to reset the dma`、`Link is Up`。

## 引导链（重点，因为本机是安卓布局）

K1 的 eMMC 是 **Rockchip 安卓式 GPT**（p1 uboot / p2 misc / p3 boot / p4 recovery / p5 backup / p6 rootfs），
**不是** Linux 的 BOOT+rootfs 布局。因此：

1. 本仓库产出的是**自包含的 Linux 布局镜像**，刷到 **SD 卡**，由镜像自带的 u-boot 从本介质引导 ——
   **全程不写 eMMC**，正在运行的厂商系统不受影响。
2. 必须防守三条安卓布局侧路（`verify-fnos-bootchain.sh` 里是硬闸）：
   - u-boot 若带 `bootrkp`/`boot_android` 且先扫到 eMMC 的 `boot` 分区 → 会去启厂商安卓系统
   - 引导配置里 `root=` 若指向 `/dev/mmcblk0*` 或厂商 PARTUUID → 会挂到 eMMC 上的厂商根分区
   - BROM 冷启动若优先 eMMC → 压根不从 SD 起（厂商 env 显示 `rkimg_bootdev` 先探 SD）
3. `idbloader.img` **内嵌板级 DDR 初始化固件**，跨板复用会 DDR 训练不匹配（实测 T68M 那份是
   `DDR V1.18`，与本板 LPDDR4@1560MHz 不符）—— 只能用为 K1 编译的那一对。

## 用法

```bash
# 1) 取本板 u-boot 对（从 kk 构建产物，带 DDR 防呆）
./fetch-uboot-from-kk.sh <kk_run_id> uboot/rk3568/kickpi-k1

# 2) 按基镜像 header 现编 4 个模块（maxio + SWT6621S 三件套；vermagic 硬闸）
./build-modules.sh <基镜像> built-modules

# 3) 装配镜像（基镜像 + u-boot + DTB + 模块注入 + depmod + 固件 + softdep）
BASE=path/to/fnnas-official-arm64-image_rockchip.img \
UBOOT_DIR=uboot/rk3568/kickpi-k1 \
DTB=dist/rk3568-kickpi-k1.dtb \
MODULES_DIR=built-modules \
./build-k1-fnos.sh

# 4) 仓库静态门禁（eMMC 劫持路径 / 预编 .ko vermagic / 网口 DT 门禁）
bash tools/verify-repo-static.sh

# 5) 六环验证（含网口 DT 门禁、modules.dep/softdep/固件/EXPECT_MODULES 断言）
EXPECT_MODULES=4 ./verify-fnos-bootchain.sh out/*.img

# 6) 刷 SD 卡（用户执行；脚本拒绝 eMMC/nvme/已挂载设备）
sudo xz -dc out/*.img.xz | sudo dd of=/dev/mmcblk1 bs=4M conv=fsync status=progress
```

## 已知限制（如实记录）

- **摄像头 gc5035**：飞牛 6.18 骨架没有 MIPI-CSI/rkisp 基础设施，强行导入会把 5.10 厂商 CSI 节点
  （含错乱引用）带进来，故剔除 —— 本产物下摄像头大概率无法工作。
- **HDMI/VOP**：保留骨架（6.18）值，K1 特有板级参数未覆盖，需上机确认。
- **SATA**：实机只有 `sata@fc000000` 是 enabled，另两个节点为 disabled（已按实机保留）。
- **WiFi MAC**：驱动移植时关闭了 Rockchip vendor storage 取 MAC 的路径（内核无该导出符号），
  改用芯片 MAC 或随机地址；如需固定 MAC 需另寻途径。
- 所有 .ko 均只完成**编译与静态符号校验**（vermagic 匹配、未定义符号全部命中内核符号表），
  **尚未在真机 insmod/组网实测**。
