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
| 实测 | `maxio.c` 对飞牛内核 **6.18.18-trim** 编译通过，vermagic 逐字一致 |

## 仓库内容

```
dts/rk3568-kickpi-k1.dts        板级设备树源（自包含展开式，无 #include）
dist/rk3568-kickpi-k1.dtb       预编译 DTB（sha256 c53d9896…）
tools/merge-dtb.py              可复现的合并脚本（飞牛 6.18 原生 R5S 骨架 + K1 板级覆盖，幂等）

modules/maxio.ko                Maxio PHY 驱动（为本板内核编译，vermagic 6.18.18-trim）
modules/src/{maxio.c,BUILD-RECIPE.md}
modules/swt6621s/*.ko           SWT6621S WiFi/BT 三模块（树外移植到 6.18，vermagic 同上）
modules/firmware/               SWT6621S 固件 15 个（取自实机原厂系统）
patches/wifi-6.18-port.patch    驱动移植补丁（12 文件 +64/-41，可干净应用到原始源码）

uboot/rk3568/kickpi-k1/         引导配置 + DDR 决策记录（含实测证据）
build-k1-fnos.sh                镜像装配（root= 自动取镜像自身 PARTUUID，绝不写设备）
verify-fnos-bootchain.sh        引导链六环验证
fetch-uboot-from-kk.sh          从 kk(iNextOS) 构建产物取本板 u-boot 对（含 DDR 防呆）
```

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

# 2) 装配镜像（基镜像 + u-boot + DTB + 模块注入）
BASE=path/to/fnnas-official-arm64-image_rockchip.img \
UBOOT_DIR=uboot/rk3568/kickpi-k1 \
DTB=dist/rk3568-kickpi-k1.dtb \
MODULES_DIR=modules \
./build-k1-fnos.sh

# 3) 六环验证
./verify-fnos-bootchain.sh out/*.img

# 4) 刷 SD 卡（用户执行；脚本拒绝 eMMC/nvme/已挂载设备）
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
