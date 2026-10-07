# K1 的 u-boot / DDR 固件来源（含实测证据）

## 结论
本目录的 `idbloader.img` 与 `u-boot.itb` **必须取自 kk（iNextOS）管线为 KICKPI K1 编出来的产物**
（`linux-u-boot-kickpi-k1-vendor_*.deb`），由 `fetch-uboot-from-kk.sh` 自动取用并校验。
**禁止**借用其他板子（如 LYT T68M）的 idbloader。

## 为什么（实测证据，非推测）
`idbloader.img` 内嵌【板级 DDR 初始化固件】，频率按板子 DRAM 定，跨板复用会 DDR 训练不匹配：

| 来源 | strings 抠出的 DDR 固件 | 结论 |
|------|------------------------|------|
| LYT T68M（xck-nas 仓库） | `DDR V1.18 f366f69a7d typ 23/07/17` | ✗ 不能用 |
| KICKPI K1 本机 eMMC 厂商区（LBA64 只读读出） | `DDR v1.23-03ea844c5d` / `fwver: v1.23` | 板级真相参考 |
| kk 管线默认（armbian rk35xx） | `rk35/rk3568_ddr_1560MHz_v1.21.bin` | ✓ 采用 |

K1 实机 DT 的 LPDDR4 参数为 `freq_0 = <0x618>` = **1560 MHz**，与 kk 管线的
`rk3568_ddr_1560MHz_v1.21.bin` 频率一致 —— 这也是 kk 那轮"以实机为准"核对过的点。

## 启动布局（与飞牛官方一致，两者相同）
- `idbloader.img` -> LBA 64（bs=512 seek=64）
- `u-boot.itb`    -> LBA 16384（bs=512 seek=16384）
armbian 的 rk35xx u-boot 与飞牛一样走 extlinux，故可直接承接飞牛的
`/boot/extlinux/extlinux.conf` + `/vmlinuz` + `dtb/rockchip/*.dtb` 布局。
