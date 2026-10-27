# 仓库导览（lyw-kf）—— 每个文件一行说明

> 目的：换人/换机接手时，先看这张表就知道"哪个文件是干什么的、被谁消费、能不能改"。
> 2026-10-27 整理：删除第二套模块自愈链（`assets/kickpi-k1-build-modules.sh`、`/usr/src/kickpi-k1/`、
> 构建期 git clone 上游），自愈逻辑全仓只保留一套；新增官方 R5S 对标门禁与引导参数硬门禁。

## 一、交付入口（根目录，人直接跑）

| 文件 | 作用 | 谁消费 | 可改？ |
|---|---|---|---|
| `build-k1-fnos.sh` | **镜像装配**：复制基镜像 → 注入 U-Boot 载荷 → 注入 DTB → 改 fnEnv（fdtfile/extraargs）→ 写 kernelfile/CMA 硬门禁 → rootfs 注入模块/固件/OTA 素材 → depmod → OS 层修复 → 产物校验 → xz + SHA256SUMS | 人 / CI 第 12 步 | 改判据要同步 §门禁三层 |
| `build-dtb.sh` | 在**飞牛内核树**（unifreq/linux-6.18.y）里编 `dts/` 的板级 DTS + SoC 一致性提示 + 权威判据（compatible 在树内有没有驱动引用） | 人 / CI（两条流水线都跑） | 可 |
| `build-modules.sh` | 用**基镜像自带 header** 交叉编 4 个树外模块（maxio + SWT6621S 三件），vermagic 硬闸 | 人 / CI 第 8 步 | 可 |
| `verify-fnos-bootchain.sh` | **六环引导链验证**（镜像侧）：DDR/U-Boot/DTB/引导配置/安卓劫持/飞牛特需项；含 CMA=256M、kernelfile 形态、OTA 自愈产物的硬断言 | 人 / CI 第 13 步 | 可（判据加严优先） |
| `README.md` | 结论 + 取证 + 用法 + 已知限制 | 人 | 可 |
| `PORTING.md` | 移植指南（基线事实 / 14 条踩坑总表 / 网口五层 / 启动链 / 装配 / 门禁 / 验收清单） | 人 | 可 |
| `TROUBLESHOOTING.md` | 故障复盘（串口原文 / 时间线 / 取证链 / 根因 / 修复） | 人 | 可（历史记录只补注不改写） |

## 二、设备树

| 文件 | 作用 | 谁消费 | 可改？ |
|---|---|---|---|
| `dts/rk3568-kickpi-k1.dts` | 板级 DTS 源（自包含展开式，无 #include；媒体簇已对标官方 R5S） | `build-dtb.sh`、`verify-repo-static.sh` | 改完必须让 CI 重编 `dist/` |
| `dist/rk3568-kickpi-k1.dtb` | **产物**：树内现编的 DTB（CI「只编 DTB」工作流自动回提交，不许手改） | `build-k1-fnos.sh`、全部 DT 门禁 | 手改无效，会被"dist 与 dts 现编逐字节一致"拦下 |
| `dist/rk3568-nanopi-r5s-official.dtb` | **官方 R5S 参照件**（飞牛官方 R5S 固件里那份，sha256 `95d4f336…`），媒体簇对标基准 | `tools/r5s-media-parity.py` | 不要动 |
| `dts/r5s-media-allowlist.txt` | 媒体簇对标**例外清单**（每条例外必须写理由与实机证据） | `tools/r5s-media-parity.py` | 只能新增有证据的条目 |

## 三、模块与素材

| 文件 | 作用 | 谁消费 | 可改？ |
|---|---|---|---|
| `modules/src/maxio.c` | Maxio MAE0621A PHY 驱动源（树外自建版，绕开新版 LED API） | `build-modules.sh`、`build-k1-fnos.sh`（下发到镜像） | 慎改（改了三处一起编） |
| `modules/src/BUILD-RECIPE.md` | maxio.ko 构建配方与已知坑 | 人 | 可 |
| `modules/src/WIFI-SRC-ORIGIN.txt` | `wifi-src.tar.gz` 的来源与重新生成步骤（provenance） | 人 | 可 |
| `modules/wifi-src.tar.gz` | SWT6621S 整棵源码（已打本仓 6.18 补丁），随镜像下发供设备端重编 | `build-modules.sh`、`build-k1-fnos.sh` | 只能按 ORIGIN 说明重新生成 |
| `modules/ota/modules-ensure.sh` | **唯一**的板级模块编译实现（maxio + WiFi/BT 三件；可传内核 release；只编不加载；失败不阻塞开机） | 镜像内 systemd 单元 / postinst 钩子 | 可 |
| `modules/ota/kickpi-k1-modules-ensure.service` | 开机补编单元（`Before=kickpi-k1-modules.service`） | 镜像 | 可 |
| `modules/firmware/SWT6621S_*`（15 个） | 实机原厂 WiFi 射频校准固件 | `build-k1-fnos.sh`（双路径注入） | 不要动 |
| `patches/wifi-6.18-port.patch` | SWT6621S 6.18 移植补丁（12 文件 +64/-41）；也是 `wifi-src.tar.gz` 的生成依据 | `build-modules.sh`、人工重建 tar | 可 |
| `uboot/k1-ki-first32m.bin` | 引导件（lyw-ki 仓 iStoreOS 构建件前 32MiB：U-Boot 2025.10-OpenWrt-r33609 + ddr-v1.23 + mmc 优先 + fdt_fixup_memory） | `build-k1-fnos.sh`（注入载荷区 [17408,32MiB)） | 只能整件替换并核 `uboot/SHA256SUMS` |
| `uboot/SHA256SUMS` | 引导件摘要 | 人 / 门禁 | 跟件一起更新 |

## 四、镜像内注入件（assets/）

| 文件 | 作用 | 落点 |
|---|---|---|
| `assets/fnos-fix-log-errors.sh` | 存量系统在线修复 + 首启自愈（清历史 EEE 关闭件 / mask 厂商单元 / webdav 权限 / K1 卡脏位 / **CMA 归一到 256M** / 装 watchdog） | `/usr/local/sbin/` + `fnos-fix-log-errors.service` |
| `assets/zz-kickpi-k1-modules` | 内核 postinst 钩子：装新内核即按该 release 调 `modules-ensure.sh`（头文件未就绪则留标记） | `/etc/kernel/postinst.d/` |
| `assets/kickpi-k1-load-modules` | **唯一**加载入口：按 `uname -r` 定位，maxio→stmmac→dwmac_rk→WiFi/BT | `/usr/local/sbin/` |
| `assets/k1-collect-boot-logs.sh` + service + timer | 每次开机在 `/boot/k1logs` 落两份日志快照（45s / 180s），供离线精读 | `/usr/local/sbin/` + units |

## 五、门禁与工具（tools/）

| 文件 | 拦什么 | 挂在哪 |
|---|---|---|
| `tools/verify-repo-static.sh` | 仓库静态门禁总入口：eMMC 劫持路径 / EEE 关闭件回归 / DTB 与 dts 一致 / 媒体簇对标 R5S / 媒体层 / 网口 DT / 废弃件回归 / 构建期联网 / 文档可执行位 | CI 第 11 步 |
| `tools/r5s-media-parity.py` | 媒体簇（GPU/NPU/VPU/RGA/JPEGD/IEP/mpp-srv/IOMMU/OPP）与官方 R5S 逐节点逐属性对标；phandle 引用解析成目标节点名 | 静态门禁 + 「只编 DTB」流水线 |
| `tools/verify-k1-net-dts.sh` | 网口 DT 五层坑（复位单持有 / clock parents / PHY 与 queue0 干净 / 无 realtek / 四延迟） | 静态门禁 + 六环 |
| `tools/verify-k1-media-dts.sh` | 转码死机防回归（IOMMU 串形态 / vepu 命名 / rkvdec 锁频与去 OPP / 媒体单元齐全） | 静态门禁 + 「只编 DTB」 |
| `tools/fit-resign.py` | FIT 内负载改动后的哈希校验/重签（不重签 SPL 必拒载） | 装配 2c + 六环 |
| `tools/patch-uboot-boot-targets.py` | `boot_targets` 等长改写 + 断言（现役引导件本就 mmc 优先，退化为断言） | 装配 2b |
| `tools/dtb-soc-consistency.py` | 与"树里某块 rk3568 参考板"的 compatible 首串对照（**仅提示**，不作判据） | `build-dtb.sh` |
| `tools/tests/kf-boot-gate-test.sh` | 引导参数硬门禁单元测试（9 例：kernelfile 存在/大小/形态、cma 256M、悬空自动纠正） | CI 第 4 步（构建前，秒级） |
| `tools/offline-read/` | Windows 免驱离线读盘（ext4 列举/提取、btrfs 列举/提取、原始盘对齐读） | 人（取证用） |

## 六、CI

| 文件 | 作用 |
|---|---|
| `.github/workflows/build-fnos-kickpi-k1.yml` | 整机镜像流水线：自测 → 取基镜像（latest 自适应 + SHA256SUMS 双校验）→ 编模块 → **编 DTB** → 静态门禁 → 装配 → 六环验证 → 产物防呆 → artifact + Release；`concurrency` 同分支只留一条 |
| `.github/workflows/build-dtb.yml` | 只编 DTB：核树编译 → 媒体/网口门禁 → 上传 → **自动回提交 `dist/`**（本机没有 dtc 时的正规出件路径） |
| `.gitattributes` | `eol=lf`（API 推 blob 时必须自己保证 LF，否则 bash 报 `pipefail invalid option`） |

## 七、文档

| 文件 | 作用 |
|---|---|
| `docs/OTA-验收单.md` | 在线升级后 P1/P2/P3 验收（四模块自愈 / 网口速率与计数 / WiFi/BT / CMA=256M） |
| `docs/REPO-MAP.md` | 本文件 |

## 八、不在仓库里的东西（别去找）

- `.ko`：一律按基镜像 header 现编（`build-modules.sh`），不进库
- 基镜像 / 产物镜像 / `out/` / `built-modules/` / `kernel/`：`.gitignore` 已忽略
- 板级预编译 DTB 的"旧兜底件"：没有，DTB 一律由 `dts/` 现编
