# KICKPI K1 × 飞牛 适配故障复盘（2026-10-12）

> 本文记录当天全部问题、取证过程、根因与修复，供日后复现排查。所有结论都来自
> 串口日志 / RKDevTool 日志 / TF 卡直读 / 官方基镜像逐字节比对，不是推理。

## 0. 速查表

| # | 现象 | 根因 | 修复 | 验收判据 |
|---|------|------|------|----------|
| 1 | 刷 eMMC 后上电停在 SPL，没有任何启动迹象 | 就地改写 FIT 内 u-boot 负载的 `boot_targets` 却没重算 sha256 | `tools/fit-resign.py` 重签 + 构建期硬门禁 + 验证环 | `python tools/fit-resign.py <img>` 输出 `总计 8 个 image 节点，0 个异常` |
| 2 | 在线更新后双网口彻底起不来 | 更新装了新内核，板级 .ko 只在旧内核目录、开机单元写死 release | 模块跟着内核走（postinst 钩子 + 开机自愈，不钉内核） | **✅ 已实测验证 2026-10-12 18:52**：更新装 c1145 → 钩子自动编出 maxio → `MAE0621A READY` ×2、`Link is Up`（见 §2.1） |
| 3 | TF 卡与 eMMC 同镜像并存可能串盘 | 仓库自造 `extlinux.conf` 静态写死 `root=PARTUUID=`，值继承自基镜像、所有产物相同 | 改回飞牛官方 boot.scr 链路（`part uuid` 现场取） | `boot.cmd` 含 `part uuid`、镜像内**不存在** `extlinux/extlinux.conf` |
| 4 | Windows 看不见移动硬盘里的资料 | 硬盘是 ext4，Windows 无 ext4 驱动（硬件没坏） | 用仓库 `tools/offline-read/` 直读（管理员权限，免装驱动） | 能列出根目录并拷出文件 |
| 5 | WiFi：`mmc_host mmc2` 不注册、扫卡失败、无 wlan0 | ①`sdio-pwrseq` 缺 `reset-gpios` ②飞牛无原厂 wlan-platdata 驱动（没人拉 `WIFI,poweren_gpio`）③pinctrl config `0x129` 指向 i2s（phandle 错乱）；另有固件未装进 `seekwave/` 子目录 | pwrseq `reset-gpios = gpio3 PD5 + ACTIVE_LOW` 代劳上电 + delay 1000ms + config 换 `0xc1` + 固件双路径注入 | **✅ 实测**：`mmc2: new UHS-I SDR104 SDIO card` → `boot sucessfull` → wlan0 → nmcli 扫 7 个 AP（信号100/405M） |
| 6 | NPU（灵魂配置）：`probe failed -22`、无 NPU 设备 | 三层：①飞牛 pm_domain 冷启动 pwrup idle 握手失败（ack 0x1ee）挡 `iommu@fde4b000` probe ②NPU 无 iommu group → `rknpu_probe` 源码 1331 行 `iommu_group_get==NULL → -EINVAL` ③DRM 模式无 `/dev/rknpu` + 推理需 root | `iommu@fde4b000 status=disabled` 走 rknpu **non-iommu 逃生门** + `interrupt-names=npu_irq`；推理用 root | **✅ 实测**：冷启动零干预 root 推理 → `init_runtime:0` → 输出 `(1,768)` → 中断 `0→25` → 域自动 pwrup on/active（见 §2.3） |

---

## 1. 刷 eMMC 起不来 —— FIT 哈希被自己的补丁打坏

### 现象（串口原文，COM3 / CH340 / **1500000** 波特）

```
U-Boot SPL 2026.04-TRIM-c218-00069-g6ddd9db8385c (Jun 15 2026 - 06:37:01 +0000)
Trying to boot from MMC1
## Checking hash(es) for config config-1 ... OK
## Checking hash(es) for Image atf-1 ... sha256+ OK
## Checking hash(es) for Image u-boot ... sha256 error!
Bad hash value for 'hash' hash node in 'u-boot' image node
spl_load_simple_fit: can't load image loadables index 0 (ret = -1)
mmc_load_image_raw_sector: mmc block read error
SPL: Unsupported Boot Device!
Trying to boot from MMC2
Card did not respond to voltage select! : -110     ← TF 卡槽没插卡（卡在读卡器里）
...
SPL: failed to boot from all boot devices
### ERROR ### Please RESET the board ###
```

**判读要点**：`config-1` 和 `atf-1` 都校验通过、只有 `u-boot` 节点失败 →
说明不是"写坏了"，而是**负载内容被改过、哈希没跟着改**；跟 eMMC 本身无关
（TF 卡刷同一个镜像一样起不来）。

### 根因

提交 `c2cd993`（2026-10-12）新增 `tools/patch-uboot-boot-targets.py`，
`build-k1-fnos.sh` 步骤 2b 调用它，把 FIT 内 **u-boot 负载**里的

```
boot_targets=usb mmc1 mmc0 nvme scsi pxe dhcp spi     （官方原值）
boot_targets=mmc1 mmc0 usb nvme scsi pxe dhcp spi     （补丁后，等长 13 字节差异）
```

就地改写（目的是 USB 不再抢引导）。等长替换、env CRC 不用改，
**但 FIT `u-boot` 节点的 sha256 是对负载算的** —— 没人重签 → SPL 校验必然失败。

### 取证过程（可复现）

1. 串口拿到 `sha256 error!`（见上）。
2. 与官方基镜像逐字节比对（基镜像只需解压前 16 MiB）：
   ```
   基镜像 fnnas-official-arm64-image_rockchip.img.gz（FIT@0x800000）
     u-boot 节点校验 → OK
   KICKPI-K1_34.img（CI run #34）
     u-boot 节点校验 → MISMATCH
   两者在 FIT 区域的差异 = 13 字节（0x8ae890 附近的 boot_targets 串）
   ```
3. FIT 自校验脚本（已入库）：
   ```bash
   python tools/fit-resign.py C:/path/to/image.img          # 只校验
   python tools/fit-resign.py --fix C:/path/to/image.img    # 重签并复核
   ```
   输出示例：`总计 8 个 image 节点，0 个异常`。

### 踩坑记录（重要）

- **FIT 负载起点 = `data-offset` + FDT `total_size`**，不是 `data-offset` + 4096。
  最初按 4096 算，8 个节点全 MISMATCH，差点误判"镜像整体损坏"。
- RKDevTool 日志里 `RunProc is ending, ret=1` **不代表失败**（成功流程也是 ret=1），
  不要拿它当判据，以串口为准。
- 串口波特率是 **1500000**（`boot.cmd` / `extlinux.conf` 里 `console=ttyS2,1500000`）。
  MobaXterm 会话里存的 2500000 是错的，用它只能看到乱码/无输出。

### 修复与门禁

- 新增 `tools/fit-resign.py`：`--verify` / `--fix`（32 字节等长重写，FDT 布局不变，
  写完自动复核；重签前把 FDT 备份为 `<镜像>.img.fitbak`）。
- `build-k1-fnos.sh` 新增 **2c**：步骤 2b 改完 FIT 内负载后强制 `--fix` + `--verify`，
  校验不过直接 `fail` 构建失败。
- `verify-fnos-bootchain.sh` 新增 FIT 哈希环：镜像任何 image 节点哈希不自洽即判红。

---

## 2. 在线更新后网口全灭 —— 板级模块没跟着内核走

### 现象

TF 卡系统功能全部正常，点飞牛「在线更新」之后，双千兆网口再也起不来
（灯不亮、拿不到地址），系统本体仍在跑。

### 时间线（全部来自 TF 卡直读，不是回忆）

| 时间 | 事件 | 证据文件 |
|------|------|----------|
| 13:44:44 | 最后一次正常开机，**网口完全正常**：`end0/end1 PHY [MAE0621A-Q2C]`、`phy_id=0x7b744411` ×2、`Link is Up` ×4 | `/boot/k1logs/20261012-134444-boot-6382687e-full.txt` |
| 13:53:51 | `install linux-image-6.18.18.c1145-trim` 开始 | `/var/log/dpkg.log` |
| 13:54:29 | 新内核 configure 完成；**`/vmlinuz` 软链切到 `vmlinuz-6.18.18.c1145-trim`** | BOOT 分区 inode mtime + `dpkg.log` |
| 13:54:33 | `update-extlinux` 重写 `extlinux/extlinux.conf`（fdt 仍是本板 DTB、root= 未变） | BOOT 分区 inode mtime |
| 14:00:10 | `install linux-modules-trim-6.18.18.c1145-trim` | `/var/log/dpkg.log` |
| 14:04:49 | 出现 `/need-depmod` 标记 | BOOT 分区 |

### 根因（对照实测）

```
/usr/lib/modules/6.18.18.c951-trim/updates/kickpi-k1/   ✅ 存在
      maxio.ko 898336 / swt6621s_wifi.ko 17519576 / skwbt.ko 1887200 / skw_sdio_lite.ko 3642152
/usr/lib/modules/6.18.18.c1145-trim/updates/kickpi-k1/   ❌ FileNotFoundError（不存在）
```

- 这些是**树外模块**：`maxio.ko` 是 Maxio MAE0621A PHY 驱动，主线和飞牛内核里都没有
  （见 README「双千兆网口：取证结论与修复」）。
- 开机单元 `kickpi-k1-modules.service` 里的 `insmod` 路径**写死了构建期的 release**。
- 于是新内核起来后：MAC 驱动（`stmmac`/`dwmac_rk`，官方自带）在，
  **PHY 驱动不在** → PHY 绑不上 MAE0621A → 链路永远起不来，正是 README 根因 #2/#5 的复现。

### 修复（不钉死内核，跟着更新走）

| 文件 | 作用 |
|------|------|
| `assets/kickpi-k1-build-modules.sh` | 对**指定内核**本机重编 4 个模块，装进 `/usr/lib/modules/<该内核>/updates/kickpi-k1/`；幂等（已有可用 .ko 就跳过）、vermagic 不符不安装、失败不破坏既有 .ko、全程记 `/var/log/kickpi-k1-modules.log` |
| `assets/zz-kickpi-k1-modules` → `/etc/kernel/postinst.d/` | 每装一个新内核自动触发上面对该内核的构建；头文件没到位就写 `/var/lib/kickpi-k1/needs-build-<rel>` 标记，开机补编 |
| `assets/kickpi-k1-load-modules` + `kickpi-k1-modules.service` | 加载与自检一律按 `uname -r` 定位，不再写死 release |
| `build-k1-fnos.sh` 注入 | 把源码放进 `/usr/src/kickpi-k1/`（`maxio.c` + 已打 `patches/wifi-6.18-port.patch` 的 SWT6621S 树） |

**可行性前提（实测确认）**：基镜像自带 `build-essential 12.9 / gcc-12 / make`，
且每个 `linux-image-*` 都配套装了 `linux-headers-<同版本>`（c951、c1145 两套 headers 都在系统里）。

### 验收判据

```bash
# maxio 必须在当前内核目录；WiFi/BT 由官方 updates/trim/seekwave-swt6621s 提供
ls /usr/lib/modules/$(uname -r)/updates/kickpi-k1/
ls /usr/lib/modules/$(uname -r)/updates/trim/seekwave-swt6621s/
sudo dmesg | grep -E "MAE0621A|phy_id=0x7b744411|Link is Up"
grep -E "maxio|kickpi" /var/log/kickpi-k1-modules.log
```

### 2.1 实测验证：2026-10-12 18:45 在线更新 → 18:52 自愈成功 ✅

整机跑的是 CI 按 `1b26769`+`4b9d1c5` 构建的镜像，做了一次**真实的飞牛在线更新**，
结果：**内核换了、网口最终自己回来了**。设备端日志（SSH 直取，可复跑）：

| 时间 | 事件 | 证据 |
|------|------|------|
| 18:45:49 | `upgrade linux-image-arm64 6.18.18.c951-trim → 6.18.18.c1145-trim` | `/var/log/dpkg.log` |
| 18:39–18:45 | 官方 `/etc/kernel/postinst.d/15-update-ukernel-ver` 把 `fnEnv.txt` 的 `kernelfile=` 写成新内核文件 | `ls -l /boot/fnEnv.txt` |
| 18:52:09 | 我们的 `zz-kickpi-k1-modules` 触发：`目标内核 6.18.18.c1145-trim` | `/var/log/kickpi-k1-modules.log` |
| 18:52:24 | `✓ maxio.ko 已装入 /usr/lib/modules/6.18.18.c1145-trim/updates/kickpi-k1` | 同上 |
| 18:52:47 | `modules.dep` 登记 maxio（`grep -c maxio` = 1） | `/usr/lib/modules/<rel>/modules.dep` |
| ~18:53 | 网口灯亮、拿到 `192.168.10.129` | 用户观察 + `ip -br a` |

**dmesg（sudo）**：

```
[61.906789] MAE0621A READY
[62.034695] rk_gmac-dwmac fe2a0000.ethernet end0: PHY [stmmac-0:00] driver [MAE0621A-Q2C Gigabit Ethernet]
[62.162517] MAE0621A READY
[62.290690] rk_gmac-dwmac fe010000.ethernet end1: PHY [stmmac-1:00] driver [MAE0621A-Q2C Gigabit Ethernet]
[66.442565] rk_gmac-dwmac fe010000.ethernet end1: Link is Up - 1Gbps/Full
```

> `end0` 是 `NO-CARRIER / carrier=0`，**没插网线**，不是故障；
> `MDIO device at address 1 is missing` 是占位节点的预期输出（见 README 网口章节，无害）。

**机制闭环（这次实测确认的完整链条）**：

```
官方 15-update-ukernel-ver（字母序 15）
   └─ 把 fnEnv.txt 的 kernelfile= 指向刚装的新内核
我们的 zz-kickpi-k1-modules（字母序 zz，必然在 15 之后）
   └─ 对该内核本机编出 maxio.ko + 登记 modules.dep
开机 → 进新内核 → maxio 已就位 → 绑上 MAE0621A → 网口恢复
```
`zz` 前缀是**有意**的：必须排在官方内核钩子之后，官方改名也不会被超到前面去。

**新事实：WiFi 不用我们编**。官方内核包自带
`updates/trim/seekwave-swt6621s/{swt6621s_wifi,skwbt,skw_sdio_lite,skw_usb_lite}.ko`，
随内核一起更新；我们这次自编 SWT6621S 在新内核上编译失败，但**不影响任何功能**
（官方那份已在，`lsmod` 里 `swt6621s_wifi`/`skwbt` 正常加载）。

**据此改进 `assets/kickpi-k1-build-modules.sh`（本次提交）**：
1. 先探测官方 seekwave，有就跳过自编（不再在新内核上做无谓且易失败的编译）；
2. 编译失败时抽取真正的 `error:` 行（此前只看到 make 的 `Error 1` 收尾，真错误被 warning 淹没）；
3. 结果断言改为「**maxio 必须就位**」（网口硬依赖），WiFi 只要官方/自编有其一即可；
4. `depmod` 对官方目录结构的 `fstatat/alternatives` 告警不再否决流程，改用
   `modules.dep` 实际含 `updates/kickpi-k1/maxio.ko` 判定。

**复验命令（换内核后照跑）**：

```bash
uname -r                                                    # 应是新内核
ls /usr/lib/modules/$(uname -r)/updates/kickpi-k1/          # 应有 maxio.ko
ls /usr/lib/modules/$(uname -r)/updates/trim/seekwave-swt6621s/   # 官方 WiFi 四件套
sudo dmesg | grep -E "MAE0621A|Link is Up"
tail -20 /var/log/kickpi-k1-modules.log                     # 应看到本次触发记录
```

---

## 2.2 WiFi（SWT6621S）：SDIO 卡没人上电（2026-10-12 实测修复）

### 现象与根因链（三层，全部实证）

```
[1] sdio-pwrseq 缺必需属性 → pwrseq probe 失败 → sdmmc2 defer 死循环
    dmesg: dwmmc_rockchip fe000000.mmc 反复 probe + waiting_for_supplier ... supplier:platform:pinctrl
    /sys/class/mmc_host 里 mmc2【从未出现】 → 没有 SDIO 总线 → 驱动 "wait scan card time out"
[2] 即使总起来也扫不到卡：飞牛内核【没有】原厂的 wlan-platdata 驱动
    （原厂靠它读 DT 的 WIFI,poweren_gpio = gpio3 PD5 给芯片上电）→ 卡无电 → CMD0 无应答
[3] pinctrl 错乱：wifi-enable-h 的 config 第 4 项 0x129 在本树指向 i2s@fe430000
    （展开式 DTB 快照的 phandle 二次错乱；0x129 只有 i2s 一个主人，不是 pcfg）
另：seekwave 驱动请求的固件路径带子目录 seekwave/*.bin，构建只装到 /lib/firmware/ 根
    → skw_calib_download -2 → wifi service 中止 → 有卡无 wlan0
```

### 修复（R1~R5 五轮实验的定论，机理写清）

| # | 改动 | 关键机理 |
|---|------|----------|
| 1 | `sdio-pwrseq` 增 `reset-gpios = <&gpio3 0x1d 0x01>` | pwrseq 时序 `assert → delay → deassert`，**扫卡发生在 deassert 之后**：`GPIO_ACTIVE_LOW` 下 deassert=物理高电平=使能；`flag=0` 时扫卡瞬间输出的是关断电平 —— 这就是 R2/R3/R4 失败、R5 通过的全部原因（PD4/PD5 × 两极性 4 组合全试过） |
| 2 | `post-power-on-delay-ms` 0xc8→0x3e8（1000ms） | 上电稳定时间，实测通过值 |
| 3 | `wifi-enable-h` 的 config `0x129`→`0xc1` | 0xc1=`pcfg-pull-none-drv-level-2`（真 pcfg）；pin 保持 PD5(0x1d) |
| 4 | 撤掉误加的 `vmmc/vqmmc/supports-sdio` | **原厂三镜像的 mmc 节点都没有这些**；SDIO 的 3.3V 由板上常供，画蛇添足反而引入变量 |
| 5 | 构建脚本固件**双路径注入**（根 + `seekwave/`） | 驱动实际请求 `seekwave/SWT6621S_SEEKWAVE_R00001.bin` 等；设备上旧的 `seekwave/` 还缺 3 个关键 .bin |

> 附带澄清两个曾浪费时间的假线索：`wifi_chip_type="rtl8822cs"` 是 BSP 模板残留
>（官方 Debian 镜像里实装的是 `swt6621s_wifi.ko/skwbt.ko/skw_sdio_lite.ko`，芯片是 Seekwave）；
> 原厂 `pwrseq` 也【没有】`reset-gpios`（他们有专有驱动代劳，我们必须用内核标准机制代劳）。

### 验收（2026-10-12 实测）

```text
mmc2: new UHS-I speed SDR104 SDIO card at address 0001   ← 卡识别
skw_start_wifi_service wifi boot sucessfull              ← 驱动 boot
skw_calib_download: SWT6621S_SEEKWAVE_R00001.bin, size: 2372  ← 固件加载
wlan0  66:32:09:5b:f0:a3                                  ← 接口出现
nmcli device wifi list → 7 个 AP（TikTok-专用/OpenWrt_5G 信号 100、405 Mbit/s）
蓝牙同步恢复：hci0, chip version 0x5302, boot bt sucessfully
```

---

## 2.3 NPU（灵魂配置）：三层根因与 non-iommu 绕过（2026-10-12 实测修复）

### 现象

`RKNPU fde40000.npu: probe with driver RKNPU failed with error -22`、无 `/dev/rknpu`、fnOS 无 NPU。

### 彻查清单结论（一个不漏，全部排除或定位）

| 检查项 | 结论 |
|--------|------|
| 与官方 Debian/Ubuntu/Android DTB 逐项对照 | **npu/iommu/power-domain@6/clocks/supply/opp/pm_qos 全部一致**（pm_qos 同指 `qos@fe180000`；npu 三时钟同 `clock-controller@fdd20000` 0x23/0x28/0x29，600MHz）→ **DT 配置无差异，排除** |
| 8 个 npu 相关 phandle 交叉反查 | scmi/power-controller/DCDC_REG4/iommus/opp-table/pm_qos… **全对，排除 phandle 错乱**（0x129 那类问题在 npu 段不存在） |
| npu-opp-table | 7 档齐全（200M/850mV…900M/975mV），efuse/nvmem 链（`rockchip-otp0`、`npu-leakage@1c`、pvtm）完整 |
| vdd_npu (DCDC_REG4) | 500mV–1.35V、enabled、users=1，**供电正常** |
| 时钟 | `clk_npu=600MHz` 已设、`aclk_npu_pre` consumer=power-domain@6 |
| 中断 | DT 无 `interrupt-names`（**官方也没有**）→ 飞牛驱动按名取 → 补 `npu_irq` 后 `GICv3 183` 注册、日志干净 |
| **真正的 -22 出处（源码级）** | `drivers/rknpu/rknpu_drv.c` **1331 行**：`iommu_group_get(dev)==NULL → return -EINVAL`，紧跟 `rknpu iommu is enabled, using iommu mode` 打印，与 dmesg 时序严丝合缝 |

### 完整因果链（每环实证）

```
① 飞牛 6.18 rockchip-pm-domain 冷启动给 npu 域 pwrup 时 idle 握手过不去
   → "failed to get ack on domain 'npu', val=0x1ee"（54s/127s 稳定复现；
     genpd 摘要 0x1ee 的 bit6=1 恰好= npu 域未上电，与 pipe/vo 两个 on 域互验）
② iommu@fde4b000 的 power-domains=npu 域 → 该 IOMMU 控制器 probe 被挡
   → /sys/class/iommu 里独缺 fde4b000（vpu/vdec/rga/vop 四个都在）
③ npu 设备进不了任何 iommu group（group 只有 video-codec×2/rkvdec/vop）
④ rknpu_probe 1331: iommu_group_get()==NULL → -EINVAL(-22) → 无 NPU
⑤ 接口层：飞牛 rknpu 编译为 DRM_GEM 模式（无 /dev/rknpu misc 节点），
   librknnrt 2.3.2 原生支持 /dev/dri/*；但 card1 是 root:video 660 → 推理必须 root
```

### 修复（DT 侧，两处）

1. **`iommu@fde4b000 status = "disabled"`** → `rknpu_is_iommu_enable()` 检测到 disabled
   自动切 **non-iommu mode**（驱动源码的专用逃生门）→ 跳过 group → probe 通过。
   推理经实测**不需要** IOMMU（rknn 走 CMA/dma_heap 物理连续内存）。
2. **`npu@fde40000` 补 `interrupt-names = "npu_irq"`**（飞牛驱动按名取中断）。

### 验收（2026-10-12，冷启动零干预）

```text
开机 → rknpu non-iommu probe 成功（[drm] Initialized rknpu 0.9.8 minor 1）
     → npu 域 off-0（节能，正常）
root 跑 img2vec_medium.rk3568.rknn：
  init_runtime: 0 → OK 3607.7ms outs=[(1, 768)]     ← 真实推理输出
  中断 122: 0 → 25                                   ← NPU 硬件真实工作
  npu 域 自动 pwrup: off → on / active               ← runtime PM 上电成功
  ack 错误：全程 0 新增（仅开机历史一条，无害）
```

**使用注意**：
- 推理用 **root**（fnOS `ai_manager.service` 本来就是 root，不受影响）；
  测试命令：`sudo /vol1/@appcenter/trim.ai-runtime-rk3568/penv/bin/python3 <脚本>`
- 若未来飞牛内核修好 pm_domain 的 pwrup 握手，把 `iommu@fde4b000` 改回 `okay`
  即可恢复 IOMMU 模式（DT 注释里留了完整开关说明）。

---

## 3. 引导链：分区 UUID 不能写死（串盘风险）

### 官方做法（实测取证）

- 官方基镜像 BOOT 分区里**只有** `boot.cmd` / `boot.scr` / `fnEnv.txt` / `grub`，
  **没有 `extlinux/`**。
- `boot.cmd` 每次启动现场取分区身份：
  ```
  part uuid ${devtype} ${devnum}:${distro_bootpart} bootuuid
  part uuid ${devtype} ${devnum}:${distro_rootpart} rootuuid
  setenv bootargs "root=PARTUUID=${rootuuid} … ubootpart=PARTUUID=${bootuuid} …"
  ```
- 内核走 `kernelfile=vmlinuz` 软链 → 跟随最新内核，在线更新天然兼容。
- 扫描 TF 卡整套系统 22268 个文件找「设备端重新生成 UUID」的逻辑：**没有**
  （79 处命中全是 copyright / vim / os-prober 之类无关文件）。
  即官方对预刷镜像就是沿用镜像自带 UUID，"不写死"靠 `part uuid` 现场取。

### 本仓库原先的问题

`build-k1-fnos.sh` 自造 `extlinux/extlinux.conf`（静态 `root=PARTUUID=<构建期读到的值>`），
而 u-boot 优先走 extlinux。那个值**继承自官方基镜像、所有产物完全相同**：

| 项 | TF 卡（10-09 构建） | KICKPI-K1_34.img（run34） |
|---|---|---|
| rootfs PARTUUID | `e1b4e4d7-a003-4448-ade5-273ed910c9ad` | 同 |
| BOOT ext4 UUID | `08a0e1e0-2fb6-4346-b8d2-74599d189ef6` | 同 |
| rootfs btrfs UUID | `39b05fb7-ab9d-4333-8c64-84b7afde6b65` | 同 |
| 基镜像磁盘 GUID | `5c4ad667-40cb-ef47-a8c6-7ae81099761d` | 同 |

单盘没问题；**TF 卡与 eMMC 同时插、且都是这个镜像**时，内核按 PARTUUID 找根分区，
挂到哪个由探测顺序决定 → 串盘、"莫名其妙"的怪现象。

### 改动（提交 `4b9d1c5`）

- 不再生成 `extlinux/extlinux.conf`（历史存在的改名 `.k1-off` 停用），
  K1 参数写进官方 `fnEnv.txt` 的 `extraargs=cma=256M loglevel=7 ignore_loglevel`。
- 构建期硬断言：`boot.cmd` 必须含 `part uuid`、`boot.scr` 必须存在、
  `extlinux/extlinux.conf` 必须不存在，否则构建失败。
- 回退旧内核：改 `fnEnv.txt` 的 `kernelfile=/vmlinuz-<旧内核>`（官方键，boot.cmd 认）。
- 硬回退材料保留在 `extlinux/extlinux.conf.k1-static`（改回 `extlinux.conf` 即切静态链路）。
- ⚠ **boot.scr 链路尚未在 K1 实机跑通**（此前实测走的是 extlinux），刷完必须串口验收。

---

## 4. 刷写要点（RKDevTool）

- 驱动：`刷机工具/DriverAssitant_v5.1.1`；工具：`RKDevTool v3.37`
- 进 **MaskROM**：断电按住恢复孔 → 上电约 3 秒松开 → 接 USB（USB2.0 口成功率更高）
- Loader：`rk3568/MiniLoaderAll.bin`；固件：整镜像 `.img`，**起始扇区 0**，
  **勾选「强制按地址写」**（不勾会报 system 超过 flash 大小）
- 当天日志（`刷机工具/RKDevTool_v3.37_for_window/Log/Log2026-10-12.txt`）：
  - 14:32 分区式刷了厂商 update.img（uboot@0x4000 / misc / boot / recovery / rootfs，Emmc storage，CS 59632MB）
  - 14:58:52→15:01:16 整镜像刷 `KICKPI-K1_34.img` @0x0（run34）
- **刷完判据只看串口**：`Image u-boot ... sha256+ OK` 才算通过，
  见 `sha256 error!` 就是 §1 那个问题。

---

## 5. 离线读盘工具箱（Windows，免装驱动）

工具已入库 `tools/offline-read/`（这次全部在临时目录里跑过、有效；临时目录会被清理，
所以固化进仓库）。**都需要管理员权限**（读 `\\.\PhysicalDriveN`）。

```bash
pip install dissect.ext4 dissect.btrfs        # 纯 Python 解析器

# ext4 分区：列目录 / 按路径提取
python tools/offline-read/ext4extract.py \\.\PhysicalDrive1 list 1 / 3
python tools/offline-read/ext4extract.py \\.\PhysicalDrive1 extract 1 D:\\out /etc /var/log

# btrfs 分区（飞牛 rootfs 是 btrfs）
python tools/offline-read/btrfs_dump.py list    \\.\PhysicalDrive2 2 / 2
python tools/offline-read/btrfs_dump.py extract \\.\PhysicalDrive2 2 D:\\dump /var/log /etc

# 只看 FIT 哈希
python tools/fit-resign.py C:/path/to/image.img
```

### 坑

| 坑 | 说明 |
|----|------|
| Windows 读原始磁盘必须 **512 字节对齐** | `ReadFile` 偏移/长度不对齐直接 `ERROR_INVALID_PARAMETER(87)`；`diskio.RawDisk` 负责对齐+缓存 |
| 无管理员权限 | `CreateFile(\\.\PhysicalDriveN)` → `ACCESS_DENIED(5)` |
| `\\.\COM3` 打不开报 `错误 2` | 设备被别的程序占用或正在重新枚举（MobaXterm 占着就是 `错误 5`），先释放串口 |
| `ext4` 库的 `Inode.size` 不可靠 | 用 `i_size` |
| 目录遍历 | 用 `opendir()`/`iterdir()` 按 inode 走，别按路径 `inode_at()` 重解析（会退化成 O(n²)，8 万文件跑不完） |
| Windows 显示硬盘"未知" | 只是缺文件系统驱动，不是盘坏了；先看 `Get-Partition` 的类型和大小确认硬件在线 |

---

## 6. 本次涉及的路径与日志位置

- 仓库本地克隆：`C:\Users\Administrator\AppData\Local\Temp\lyw-kf`
- 串口：COM3（USB-SERIAL CH340），**1500000** 8N1
- RKDevTool 日志：`C:\Users\Administrator\Desktop\刷机工具\RKDevTool_v3.37_for_window\Log\`
- 开机日志（设备端）：BOOT 分区 `/k1logs/`（由 `assets/k1-collect-logs.timer` 每次开机写
  45s / 180s 两份 `*-full.txt` / `*-errors.txt`）——**这是最快的离线取证入口**：
  TF 卡插回电脑就能直接读。
- 已修好的可刷镜像：`C:\Users\Administrator\Desktop\刷机工具\KICKPI-K1_34.img`
  （已重签 FIT；原始 FDT 备份 `KICKPI-K1_34.img.fitbak`）
  ⚠ 该镜像仍是**旧链路**（静态 extlinux + 无模块自愈），只用于救活机器；
  放心做在线更新请用 CI 的新镜像。
- USB 移动硬盘（资料盘）：ext4，GPT 分区名 / 卷标 `hermes-work`，
  含 `/incoming` `/kbuild` `/official-dts` `/kk` `/fix` `/fnos-kb` `/repos` `/docs` `/scripts` `/logs`，
  约 49 GB；Windows 不认 ext4，读取方式见 §5。

---

## 6b. 网口间歇整口 Down（EEE/LPI）实测记录 · 2026-10-13

> 触发：用户晨间"连不上 192.168.10.129、拿不到 IP、网口灯亮"。前六层坑全修好的系统，
> 却整夜间歇掉线——排查半日定位为 EEE 省电态，两仓（lyw-OS 主路由线 / 本仓）同步修复。

- **时间线**（主路由 journalctl，17h uptime）：10-12 18:28–21:45 密集 Link Down **34 次/3h**
  （1–7 分钟一次，单次断 3s–5min 不等）→ 深夜 00:34–07:41 仅 1 次 → 07:41 用户起床时段
  两端同时 Down 5s → 09:57 两条 = 关 EEE 动作本身的一次性重协商 → **此后零掉线**。
- **判据链**：对端 `phy_eee_wakeup_error_n=8126`；`irq_rx_path_in_lpi_mode_n`=7811 万；
  两端 `rx_crc_errors=0`（排除线材/水晶头——用户独立确认硬件接口完好）；soc 37°C；
  `t68m-gmac-delay`/`gmac-phy-hold` 全程 active（排除已有修复失效）。
- **处置**（两端已生效并持久化）：`ethtool --set-eee … eee off`（eth0–3 / end0–1/wlan0）
  + `/sys/class/net/*/device/power/control` = `on`；`net-nosleep.service` active+enabled。
- **复发判据**（次日复核用）：
  ```bash
  # 主路由：41 与 0 不涨 = 收案
  journalctl -b --no-pager | grep -c 'eth1: Link is Down'
  ethtool -S eth1 | grep phy_eee_wakeup_error
  # 飞牛端：8126 不涨 = 收案
  sudo ethtool -S end1 | grep phy_eee_wakeup_error
  ```
- **固化的修复**：`assets/kickpi-k1-eee-off.sh` + `kickpi-k1-eee-off.service`（构建注入+自证）、
  `verify-repo-static.sh` 静态门禁、PORTING §3.8 坑⑦、总表 #11。详见 PORTING §3.8。

---

## 7. 验收清单（每次改动后照做）

1. `bash -n build-k1-fnos.sh verify-fnos-bootchain.sh` + `python -m py_compile tools/*.py`
2. `python tools/fit-resign.py <产物镜像>` → `0 个异常`
3. `EXPECT_MODULES=4 ./verify-fnos-bootchain.sh out/*.img` → ALL PASS
4. 实机串口验收：
   - SPL：`config-1 OK` / `atf-1 sha256+ OK` / `u-boot sha256+ OK`（**没有** `sha256 error!`）
   - 内核：`Machine model: KICKPI K1`
   - 网口：`MAE0621A READY` ×2、`phy_id=0x7b744411` ×2、`end0/end1 ... Link is Up`
   - 0 × `Cannot register the MDIO bus`、0 × `probe failed`、0 × `Failed to reset the dma`
5. 在线更新一次新内核后重复第 4 条 —— 这是「更新后网口不掉」的唯一硬判据。
