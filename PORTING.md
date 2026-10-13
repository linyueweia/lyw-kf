# KICKPI K1 (RK3568B2) → 飞牛 fnOS 移植指南

> 本文是 2026-10-12 全程适配的**在案总记录**：流程、每一个坑的根因与修复、验收判据。
> 下次给这台设备适配新系统（或给同方案 RK3568 板适配），照 §0 清单顺序走即可，
> 坑全部已有固化修复与 CI 门禁，不应再踩第二遍。
> 详细故障复盘见 [TROUBLESHOOTING.md](TROUBLESHOOTING.md)，双网口取证全文见 README。

---

## 0. 下次适配的执行清单（按序）

1. **材料**：飞牛官方基础底包 `fnnas-official-arm64-image_rockchip.img.gz`（唯一基线）；
   对照物只认官方三镜像（Debian11 / Ubuntu20.04 / Android13.0，桌面上）——Armbian 非官方仅参考。
2. **DT**：以官方 6.1 SDK `rk3568-kickpi-eth-gmac0/1.dtsi` + 官方 5.10 DTB + 实机 dump 三方对照出
   `dts/rk3568-kickpi-k1.dts`（本仓库已维护成手改成品）。改 dts 必须同步重编 dist（§3 网口判据、
   `tools/verify-repo-static.sh` 会拦）。
3. **u-boot**：**不要自编**。恒用基镜像自带（v1.23 与本板 eMMC 原厂同哈希；自建 v1.26 SPL 阶段即断）。
4. **装配**：`build-k1-fnos.sh`（基镜像 + DTB + 模块 + 固件），引导走官方 boot.scr `part uuid`。
5. **板级模块**：maxio（网口 PHY，硬依赖）按基镜像 header 现编 + 三层自愈；WiFi 用官方内核自带三件套。
6. **门禁**：本地跑 `tools/verify-repo-static.sh` + `verify-k1-net-dts.sh` 再推；CI 全绿才算完。
7. **验收**：§9 清单逐项打勾（含在线更新自愈实测）。

---

## 1. 硬件与基线事实（已验证，勿再推导）

| 项 | 值 | 来源 |
|---|---|---|
| SoC / 板 | RK3568B2，KICKPI K1 V1.2 | |
| 内存 | LPDDR4 **1560 MHz**（freq_0=0x618） | 实机 |
| 启动介质 | TF=`mmcblk1` 启动；eMMC=`mmcblk0` | 实机 |
| 双网口 | `end0`=fe2a0000.gmac0、`end1`=fe010000.gmac1，PHY **Maxio MAE0621A**（phy_id 0x7b744411，RGMII） | 实机+三方对照 |
| u-boot | 基镜像自带 armbian U-Boot 2026.04-TRIM-c218，**DDR v1.23-03ea844c5d**（=本板 eMMC 原厂同哈希） | workflow 实测结论 2026-10-08 |
| 基镜像 | 分区：BOOT(ext2, 65536s 起) + rootfs(btrfs)；内核 `6.18.18.c951-trim`（社区包 `6.18.18-trim` 后缀不同=vermagic 不同） | |
| WiFi/BT | seekwave SWT6621S（SDIO），官方内核自带 `updates/trim/seekwave-swt6621s/` | |
| NPU | rknpu，`/dev/dri/card1`（root:video 660），推理须 root（fnOS ai_manager 本为 root） | |

**三条基线决策（有实测背书，勿翻案）**：
- **u-boot 不自编**：自建对（DDR v1.26 + U-Boot 2023.10）冷启动电源灯亮系统灯不亮，SPL 阶段即断；
  基镜像 v1.23 全部成功启动用的都是它。自建素材链（`uboot/`、`build-uboot.sh`、`fetch-uboot-from-kk.sh`）已删。
- **对照只认官方三镜像**：Armbian 是"没成功的系统"，当权威会带偏。
- **内核不钉死**：板级能力靠模块自愈（§6），在线更新必须还能用。

---

## 2. 踩坑总表（现象 → 根因 → 修复 → 门禁）

| # | 现象 | 根因 | 修复 | 已固化为 |
|---|---|---|---|---|
| 1 | 刷 eMMC 起不来，串口 `sha256 error!` | 2b 就地改 FIT 内 13 字节后未重签 | 重签全部 image 节点哈希 | `tools/fit-resign.py` + 构建 2c + 验证双门禁 |
| 2 | 插 USB 硬盘开机卡死（像网口灯不亮的死机） | armbian u-boot `boot_targets=usb mmc1…` USB 优先抢启动 | 等长 patch 改 mmc 优先（36B 等长、CRC 不动、恰好 1 处命中+读回复核） | `tools/patch-uboot-boot-targets.py`（构建 2b） |
| 3 | 在线更新后双网口全灭 | maxio 只在旧内核目录、开机单元写死 release | 模块跟内核自愈（§6） | postinst + zz 钩子 + vermagic 硬闸；实测 c951→c1145 15s 恢复 |
| 4 | 网口 PHY 绑不上（Generic PHY / phy_id 全 1） | 见 §3 五层坑 | 见 §3 | `tools/verify-k1-net-dts.sh` + softdep + 占位 PHY |
| 5 | WiFi 扫不到卡 | sdio-pwrseq 缺 reset-gpios / 极性错 / pinctrl 0x129 指错节点 | PD5+ACTIVE_LOW+1000ms 等 R1–R5 实测定论 | dts 源 + CI |
| 6 | WiFi 固件 -22 / calib -2 | 驱动请求 `seekwave/` 子目录，构建只装根目录 | 双路径注入各 15 文件断言 | `build-k1-fnos.sh` |
| 7 | NPU `probe failed -22` | iommu_group_get()==NULL（pm_domain 冷启动握手失败挡 iommu probe） | `iommu@fde4b000 status=disabled` 走 non-iommu 逃生门 + `interrupt-names="npu_irq"` | dts 源 + 实测推理通过 |
| 8 | 改 dts 忘重编 dist，CI 拦下 | 门禁按设计工作 | dtc 门禁同款参数重编同步 | `verify-repo-static.sh` 逐字节 cmp |
| 9 | CI `set: pipefail invalid option name` | API blob 直传把工作区 CRLF 入库（autocrlf 只保护本地 commit 路径） | 3 文件转 LF + `.gitattributes eol=lf` + API 推送强制 LF | `.gitattributes` |
| 10 | 构建脚本 head 拿错 vermagic 编模块被拒 | 社区内核包后缀与基镜像不同 | release 一律取自基镜像 | `build-modules.sh` vermagic 硬闸 |
| 11 | 网口间歇性整口 Link Down（用网高峰 34 次/3h，深夜几乎不掉；灯亮但拿不到 IP） | EEE/LPI 省电态唤醒时序在 RK3568 dwmac + RTL8211F 翻车 → 整口重协商（对端 `phy_eee_wakeup_error_n=8126`、LPI 进出 7800 万次；两端 CRC=0 排除物理层） | 全口 `ethtool --set-eee … eee off` + `power/control=on`，开机执行带重试 | `assets/kickpi-k1-eee-off.sh` + `kickpi-k1-eee-off.service`（构建自证 + `verify-repo-static.sh` 静态门禁）；与 lyw-OS 线 `eth-eee-off` 同案同修 |

---

## 3. 网口（最重要，五层坑逐层修）

> 验收终态：`end0/end1` 都认出 `MAE0621A-Q2C`、`Link is Up - 1Gbps/Full`、灯亮。
> `end0 NO-CARRIER` = 没插网线，不是故障；`MDIO device at address 1 is missing`
> 是占位节点的预期输出（无害，见坑 4）。

### 3.1 坑① DT 复位归属：只许 MAC 侧单持有

- **现象**：双持有（MAC+PHY 都持 reset）→ `-EBUSY → Cannot register the MDIO bus`；
  完全无复位 → `MDIO device at address 0 is missing` / `-ENODEV`。
- **判据（三方一致）**：L1 实机 5.10 运行态 / L2 官方 6.1 SDK gmac0+gmac1 dtsi / L3 官方 5.10 DTB
  ——三线都只有 **MAC 侧**持有复位。
- **修复**：两个 `ethernet@` 节点保留 `snps,reset-gpio + reset-active-low + reset-delays-us`；
  **PHY 节点与 queue0 里的 reset-\* 全部删除**；两条复位线（`fe750000/0x1b`、`fe760000/0x07`）
  全局不得再被任何 `reset-gpios` 引用。
- **门禁**：`tools/verify-k1-net-dts.sh`（CI 每跑必检）：status=okay、phy-mode=rgmii、
  clock_in_out=output、MAC 侧三件套在位、assigned-clocks 三组 cell 数（4/4/2）、
  两 PHY 块不持有复位、queue0 无 reset 垃圾、全局 reset-gpios 引用计数=0。

### 3.2 坑② 内核里根本没有这颗 PHY 的驱动

- **取证**：2877 个模块、163 条 mdio 别名，`0x7b744411` **0 命中**；MAC 驱动
  stmmac/dwmac-rk 反而齐全 → 唯一路径是外挂 `maxio.ko`（Maxio MAE0621A 驱动，
  树外，主线和飞牛内核都没有）。
- **修复**：`modules/src/maxio.c` 随镜像注入 `/usr/src/kickpi-k1/`，
  装配期注入 `updates/kickpi-k1/`。

### 3.3 坑③ vermagic：必须按基镜像 header 现编

- 预编 `.ko` 是 `6.18.18-trim`，基镜像内核是 `6.18.18.c951-trim` ——差一个后缀必被拒
  （`CONFIG_MODULE_SIG/MODVERSIONS` 未开，逐字比较）。
- `build-modules.sh` / `kickpi-k1-build-modules.sh`：release **取自基镜像**（不能拿社区包），
  编完 `modinfo` vermagic 硬闸；`depmod -b` 后断言 `modules.dep` 含 `maxio.ko`
  （历史 bug：depmod 条件恒假，从未真正跑过）。

### 3.4 坑④ 加载顺序：Generic PHY 抢绑

- `dwmac_rk.ko` 由 udev 冷插拔 ~10s 拉起，`kickpi-k1-modules.service` 11.19s 才跑 →
  `phy_attach_direct()` 先绑 Generic PHY，晚到的 maxio 被跳过。
- **修复**：`etc/modprobe.d` 写 `softdep dwmac_rk pre: maxio` —— MAC 驱动加载前 maxio 必须先就位；
  insmod 单元不再 `2>/dev/null` 吞错。

### 3.5 坑⑤ GMAC4 的 MDC 时钟陷阱（最隐蔽的一个）

- **现象**：`phy_id` 被读成 `0xffff4411`（应为 `0x7b744411`）→ maxio（mask 0xffffffff）永不匹配
  → 绑 Generic PHY → 写不了 Maxio 私有页 → MAC 报 `Failed to reset the dma`。
- **根因**：`stmmac_mdio_reset()` 里"复位后补一个 MDC 时钟"的 dummy read 被
  `if (core_type != DWMAC_CORE_GMAC4)` 跳过，**而 RK3568 正是 GMAC4**（驱动注释自认
  "To be updated for GMAC4 if needed"）→ `snps,reset-gpio` 释放后 MDC 全程静止 →
  PHY 复位不完成 → of_mdio 扫描第一帧(PHYID1) 读回全 1。（8 份真机日志：3 次有 PHY 全部
  `0xffff4411`，`MAE0621A` 命中 0/8。）
- **修复（三管齐下）**：
  1. **根治**：两个 `mdio` 节点在 `phy@0` **之前**插占位 `ethernet-phy@1`——让扫描先发生一帧、
     产生 MDC 时钟，随后 `phy@0` 读到正确 ID（`of_mdio.c` 对 `-ENODEV` 只打 missing 不中断；
     `phy_device.c` 的 `(id & 0x1fffffff)==0x1fffffff → -ENODEV` 已核实）；
  2. **保险**：maxio id 表补 `{0xffff4411, 0xffffffff}`；
  3. 补回 `local-mac-address`（原为随机 MAC）。

### 3.6 坑⑥ 在线更新后网口全灭（模块不跟内核走）

- 时间线取证（TF 卡直读）：更新装 `6.18.18.c1145-trim` → 旧目录里的板级 `.ko` 失效 → 网口灭。
- **修复（不钉内核）**：
  - `dpkg` postinst 钩子：官方引导指向新内核（`15-…`）后，`zz-kickpi-k1-modules` 对
    **同一内核**现编 maxio（顺序不可颠倒）；
  - 开机单元 `kickpi-k1-load-modules` 兜底：按 `uname -r` 检查 maxio 是否就位，缺则现编装入
    `updates/kickpi-k1/` + 登记 `modules.dep`；
  - 幂等：官方 `updates/trim/seekwave-swt6621s/` 存在则跳过 WiFi 自编；maxio 三件套齐了直接 exit 0
    （否则每次开机重编、开机变慢）。
- **实测验收**（2026-10-12 18:45→18:53）：更新 c951→c1145 → 18:52:09 钩子触发 →
  18:52:24 `✓ maxio.ko 已装入 …/c1145-trim/updates/kickpi-k1` → 18:52:47 modules.dep 登记 →
  `end0/end1 PHY [MAE0621A-Q2C] ×2`、`Link is Up`、灯亮拿到 IP。

### 3.7 网口相关 DT 数值（三方一致，改 dts 别动错）

- `phy-mode = "rgmii"` ×2；`tx_delay = 0x21 / 0x2f`、`rx_delay = 0x3c / 0x39`（各计 2）；
- `clock_in_out = "output"`；assigned-clocks 2 组=4 cell、rates=2 cell；
- 每个 mdio 下 `ethernet-phy@0` 必须带 `reg = <0x00>`（缺它 → invalid PHY address → 退化 Generic PHY）；
- 不得残留 T68M 的 `realtek,` 属性。

### 3.8 坑⑦ EEE/LPI：链路间歇整口 Down（2026-10-13 实机定案，与前六层独立）

- **现象**：`end1`/对端口间歇 `Link is Down`，用网高峰（18:28–21:45）34 次/3h、深夜停网
  几乎不掉；灯亮、CRC/误码全 0，恢复后 IP 不变——与前六层坑（都表现为"起不来/丢包"）完全不同。
- **判据（缺一不可）**：
  - `ethtool -S <nic> | grep phy_eee_wakeup_error` = **8126**（EEE 唤醒失败实锤）；
  - `irq_rx_path_in_lpi_mode_n` 7800 万（网卡整夜在省电态进出循环）；
  - 两端 CRC/误码=0（排除线材/水晶头）、温度 37°C（排除过热）；
  - 掉线时段与用网高峰强相关（LPI 进出最频繁的时段 = 唤醒失败概率最高的时段）。
- **病理**：EEE（Energy Efficient Ethernet）省电态 LPI 的唤醒时序在 RK3568 dwmac +
  RTL8211F/Maxio 组合上翻车 → MAC 侧判唤醒失败 → 整口重新自协商。
  **与前六层的关系**：前六层修"网口起不来/绑不上/丢包"，这一层修"跑着跑着整口掉"——
  两个独立的病，互不替代。
- **修复**：`assets/kickpi-k1-eee-off.sh` 对所有真实网卡 `ethtool --set-eee … eee off`
  （不支持 EEE 的口自动跳过）+ `power/control=on`，15 次×2s 重试至全部成功；
  `kickpi-k1-eee-off.service`（After=NetworkManager.service）开机执行。
- **门禁**：构建自证（脚本在位/`sh -n`/`--set-eee`+`eee off` 内容/wants 链接/ethtool 依赖）
  + `tools/verify-repo-static.sh` 静态断言。
- ⚠ **历史翻案**：lyw-OS 线曾把关 EEE 当废案删除并在 CI 断言"残件必须不存在"
  （理由：当时丢包的病根是 RGMII 时序，时序修好后误判 EEE 无罪）。本实机证据推翻该决定，
  两仓已同步重装修复件并翻转断言——勿再按"官方默认不动 EEE"回退。

---

## 4. 启动链（eMMC/TF 都要能起）

1. **u-boot**：基镜像自带，装配不覆盖（LBA64 idbloader / LBA16384 u-boot.itb 原样）。
   Report/Show outputs 有产物 DDR 断言：必须 `v1.23`，拒绝 `V1.18 f366f69a7d`（T68M）与 `1056MHz` 家族。
2. **2b boot_targets**：等长 patch（`usb mmc1…` → `mmc1 …`，36B 等长、CRC 不动、
   恰好 1 处命中 + 读回复核）。没它 → 插 USB 硬盘开机被抢跑。
3. **2c FIT 重签**：2b 改了 FIT 内负载 → `tools/fit-resign.py --fix` 后**必须复核通过**，
   否则 SPL `sha256 error!` 必然起不来（血的教训，串口原文见 TROUBLESHOOTING §1）。
4. **boot.scr 官方链**：走飞牛官方 `boot.scr`，`part uuid` 现场取分区身份——**不写死 UUID/PARTUUID**
   （TF/eMMC/换卡都通用）；删自生成 extlinux.conf（历史坑：它曾把 root 指向厂商 eMMC 分区
   `mmcblk0p2`，`verify-repo-static.sh` 因此盯着"eMMC 劫持路径/厂商 PARTUUID"）。
5. **内核不钉死**：`KREL` 从 BOOT 分区 `vmlinuz-*` 自动探测，跟随官方更新。

---

## 5. 镜像装配要点（build-k1-fnos.sh）

- 入参：`BASE=基镜像 DTB=dist/….dtb MODULES_DIR=built-modules`（UBOOT_DIR 已删除）。
- 安全闸：BASE 禁止 `/dev/*`（防把设备节点当镜像写）；umount 加固（sync+重试+惰性卸载）。
- 模块注入：`/usr/src/kickpi-k1/`（源码，供开机现编）+ `updates/kickpi-k1/`（预编，供首启）+
  `etc/modprobe.d` softdep + `depmod -b` 断言。
- 固件双路径：`/lib/firmware/` 根 + `seekwave/` 子目录（驱动只认后者），各 15 文件断言。
- 产物：`out/KICKPI-K1_<n>.img(.xz)` + SHA256SUMS。

---

## 6. WiFi / BT（R1–R5 实测定论）

- **上电**：内核标准 pwrseq 机制（原厂 wlan-platdata 驱动飞牛内核没有）：
  `sdio-pwrseq` 的 `reset-gpios = <&{/pinctrl/gpio@fe760000} 0x1d 0x01>` = **PD5 + ACTIVE_LOW**
  （deassert=物理高=使能；R2/R3/R4 用 flag=0 全失败的原因）+ `post-power-on-delay-ms = 0x3e8`(1000ms)。
  pinctrl `wifi-enable-h` config 换 `0xc1`（config 0x129 曾指向 i2s 节点=phandle 错乱）。
  另需 `sdmmc2 supports-sdio`、fe000000.mmc 挂 `mmc_host`。
- **固件**：双路径注入（坑 ⑥）。
- **三件套**：官方内核自带，不自编；`seekwave_boot_parse_dt` 读 `dma_type/gpio_chip_en` 后
  `devm_gpio_request_one(…, GPIOF_OUT_INIT_HIGH, "CHIP_EN")`。
- **验收**：`mmc2: new UHS-I SDR104 SDIO card` → `boot sucessfull` → `wlan0` → `nmcli` 扫到 AP；
  蓝牙 `hci0` chip 0x5302。

---

## 7. NPU（"灵魂配置"）

- 彻查 10 项全一致（pm_qos 0x117→/qos@fe180000、8 个 phandle、npu-opp-table 7 档、nvmem/efuse、
  三 supplier、clk_npu=600MHz、官方三镜像 DTB 对照）——**DT 侧无罪**。
- 根因：`rknpu_drv.c:1331` `iommu_group_get(dev)==NULL → -EINVAL`（飞牛 6.18 pm_domain
  冷启动 pwrup 握手失败挡住 iommu probe）。
- 修复（dts 两处）：`iommu@fde4b000 status="disabled"`（走 non-iommu 逃生门，注释写清回退开关）
  + `npu@fde40000 interrupt-names="npu_irq"`。
- 验收：root 跑 `img2vec_medium.rk3568.rknn` → `OK 3607.7ms outs=[(1,768)]`；
  `/proc/interrupts` `122:` 0→25；npu 域自动 pwrup off→on/active，冷启动零干预。
  推理须 root（`/dev/dri/card1` root:video 660）。

---

## 8. 门禁体系（CI 全绿的构成）

| 门禁 | 拦什么 | 工具 |
|---|---|---|
| eMMC 劫持 / 厂商 PARTUUID | root 指错分区、写挂厂商系统 | `tools/verify-repo-static.sh` |
| dist DTB ↔ dts 源逐字节一致 | 改 dts 忘重编（`dtc -f -Wno-pci_device_reg -Wno-unit_address_vs_reg -I dts -O dtb`） | 同上 |
| 网口 DT 门禁 | §3 判据任何一条回归 | `tools/verify-k1-net-dts.sh` |
| FIT 哈希自洽 | 改 FIT 不重签 → SPL 拒载 | `tools/fit-resign.py`（构建 2c + verify 双卡） |
| vermagic / 预编 .ko | 编错内核的模块 | `build-modules.sh` 硬闸 + 静态门禁 |
| 产物 DDR 断言 | u-boot 换错（非 v1.23 / T68M / 1056MHz） | workflow `Show outputs` |
| 六环引导链 | 引导配置回归 | `verify-fnos-bootchain.sh` |
| 行尾 | CRLF 入库炸 bash | `.gitattributes eol=lf`（API 推 blob 必须强制 LF） |

**工程约定（吃过亏的）**：
- 推送走 Git Data API 时（github.com 间歇阻断），blob 必须先 `replace(b"\r\n", b"\n")`——
  autocrlf 只保护本地 `git commit` 路径，API 直传会把工作区 CRLF 原样入库。
- CI 失败先抓 run zip 日志（`/actions/runs/{id}/logs` 302 到 S3，别把 Authorization 带过去）。
- workflow 里"构建前清单"类步骤不要放产物断言（产物还不存在）。

---

## 9. 验收清单（下个系统照此打勾）

**启动**：冷启动灯语正常（电源+系统灯）；TF/eMMC 都能起；插 USB 硬盘不抢启动；
串口无 `sha256 error`；`part uuid` 链换卡可启。

**网口（重点）**：
```
dmesg | grep -E "MAE0621A|Link is Up"      # end0/end1 各认出 PHY，至少一口 Link Up
ip -br a                                    # end0/end1 拿到 IP（没插线的口 NO-CARRIER 正常）
ethtool end0 end1                           # 1Gbps/Full
```
DT 侧：`bash tools/verify-k1-net-dts.sh` 全 OK。

**在线更新自愈（必须实测一次）**：飞牛在线更新 → 新内核 →
`grep -E "maxio|kickpi" /var/log/kickpi-k1-modules.log` 有新内核的装入记录 → 网口自己回来。

**WiFi/BT**：`nmcli dev` 有 wlan0 且能扫 AP；`hciconfig` 有 hci0。
**NPU**：root 跑 rknn 模型 OK + `/proc/interrupts` 122 行计数增长。
**CI**：main 全绿（全部门禁通过）。

---

## 10. 相关文件索引

- 构建：`build-k1-fnos.sh`、`build-modules.sh`、`.github/workflows/build-fnos-kickpi-k1.yml`
- DT：`dts/rk3568-kickpi-k1.dts`、`dist/rk3568-kickpi-k1.dtb`（同步重编）
- 门禁：`tools/verify-repo-static.sh`、`tools/verify-k1-net-dts.sh`、`tools/fit-resign.py`、
  `tools/patch-uboot-boot-targets.py`、`verify-fnos-bootchain.sh`
- 模块自愈：`assets/kickpi-k1-build-modules.sh`、`assets/zz-kickpi-k1-modules`、
  `assets/kickpi-k1-load-modules`、`assets/kickpi-k1-modules.service.new`
- 复盘：`TROUBLESHOOTING.md`（串口原文/时间线/取证链）、README（双网口 5 条取证结论）
- 取证工具：`tools/offline-read/`（Windows 免驱读 ext4/btrfs/原始盘）
