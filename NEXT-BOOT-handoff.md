# KF 网口任务 —— 交接与下次开机判读（2026-10-12）

> 目的：网关跑在 eMMC 的 Ubuntu 上，断电从 TF 卡起 fnOS 时会离线。
> 这份文档让回来的我立刻接上，不用重新推导。

## 现在到哪一步了

**TF 卡已 dd 完成并逐项读回验证**（镜像
`/work/kbuild/kf-build/out/KICKPI-K1_20261009.img`，mtime 2026-10-12 08:35）。
卡已卸载、无挂载，可以断电。**下一步只剩：断电重上 → 跑 fnOS → 拔卡回 Ubuntu → 读日志。**

**必须断电重上，不能 `reboot`**：`/work/kk/K1-实机取证.md` 实测 u-boot
`boot_targets=mmc1 mmc0`、`rkimg_bootdev` 先探 SD，热 reboot 会回落 eMMC。

**卡插着 → 起的是 fnOS → 网关不在 → 我离线**，这是预期不是故障。

## 根因（已查到源码级，不要再重推）

`phy_id` 读成 `0xffff4411` 而不是 `0x7b744411`，链路：

```
stmmac_mdio_reset() 里那条「复位后补一个 MDC 时钟」的 dummy read
被 if (core_type != DWMAC_CORE_GMAC4) 跳过，而 RK3568 正是 GMAC4
（驱动注释自认 "To be updated for GMAC4 if needed"）
  → snps,reset-gpio 释放后 MDC 静止 100ms，PHY 复位不完成
  → of_mdio 扫描第一帧 (PHYID1) 读回全 1 = 0xffff
  → phy_id = 0xffff4411（phy_device.c: *phy_id = physid1<<16 | physid2，无掩码）
  → maxio 要 0x7b744411 / mask 0x7fffffff → 不匹配
  → 绑 Generic PHY → 写不了 Maxio 私有页 (page 0xd8f~0xda5)
  → "otherwise a DMA reset error occurs"（maxio.c 源码注释原话）
  → Failed to reset the dma → DMA engine initialization failed → Hw setup failed
  → Link is Up 0 次 / 8 份日志 → 灯不亮、两口不通
```

**旁证**：只有 PHYID1 错、PHYID2(0x4411) 正确 = 「第一次事务 NACK、第二次成功」的指纹；
有 PHY 的 3 次启动全是 `0xffff4411`；第 7-8 份 `snps,reset-gpio` 消失则连 PHYID2 都读不到。

## 本次四笔改动（已进卡，仓库未推送）

| # | 改动 | 文件 |
|---|---|---|
| 1 | 两个 `mdio` 节点在 `phy@0` **之前**插占位 `ethernet-phy@1`（先被扫描→补 MDC 时钟）| `dts/rk3568-kickpi-k1.dts` |
| 2 | maxio id 表补 `{0xffff4411, 0xffffffff}`（保险）| `modules/src/maxio.c` |
| 3 | 补回 `local-mac-address`（`9e:e7:…`/`9a:e7:…`，与宿主机一致）| 同 DTS |
| 4 | 显式加载 `stmmac`+`dwmac_rk`；修 `ExecStart` 引号（原 `sh -c` 只跑第 1 条）| `build-k1-fnos.sh` |

门禁：五合一 DT / 仓库静态 / 六环引导链 / 网口 DT —— **全部 ALL PASS**。
备份：`*.bak-pre-mdio-warmup`、`*.bak-pre-ffffid`、`*.bak-pre-dwmacfix`。

**修法安全性已核**：`of_mdio.c` 第 175 行 `rc == -ENODEV` 只打印 `missing` 并继续，
不会 `goto exit` 中断注册；`phy_device.c` 的 `(id & 0x1fffffff) == 0x1fffffff → -ENODEV`
保证空地址精确返回 -ENODEV；`dtc` 实测保留节点顺序 `phy@1 → phy@0`。

## 下次开机日志怎么读

路径：插卡回 Ubuntu 后 `/media/kickpi/BOOT/k1logs/*-full.txt`（采集 45s + 180s 各一份，
保留 8 组，本次是全新空目录 → 只会有这次的日志）。

| 关键字 | 含义 |
|---|---|
| `phy_id=0x7b744411` + `MAE0621A` + `Link is Up` | **彻底完成** ✅ |
| `phy_id=0xffff4411` 但有 `MAE0621A READY` | 保险条目生效，也算通 |
| 仍无 `MAE0621A` / `MDIO device at address 0 is missing` | 失败 → 看 `dmesg` 卡在哪一步 |
| `MDIO device at address 1 is missing` | **无害**，是占位节点的预期输出 |

验收门（`modules/src/BUILD-RECIPE.md` 底部）：0 × `Cannot register the MDIO bus`、
0 × `probe failed`、`end0/end1` 驱动 `rk_gmac-dwmac`、`phy_id=0x7b744411`、
0 × `Failed to reset the dma`、出现 `Link is Up`。

## 历史教训

- **别靠推理下结论**：本地有 8 份真机日志 + `K1-实机取证.md` + `fix-maxio-patch.py`，
  我整晚做静态分析没读，被用户点名才去看；期间还给过一个被日志直接推翻的结论
  （「MAC 驱动没加载」——实际 8 次全加载了）。
- `/work/docs/eth1-*` 是 **T68M** 的，与 KF 无关，不要混引。
- QEMU 没有 RK3568 GMAC 模型，虚拟机永远测不了 GMAC probe/PHY 绑定/link。
