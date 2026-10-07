# KICKPI K1 (RK3568B2) u-boot 引导件 — 构建来源与校验

本目录的 `idbloader.img` / `u-boot.itb` 由仓库根目录的 **`build-uboot.sh`** 自构建产出
（直接用 u-boot 源码 + rkbin，**不依赖 armbian 框架**），并由脚本内置的 DDR 频率防呆校验放行。

## 构建输入（可复现，脚本已钉版本）

| 项 | 值 |
|----|----|
| u-boot 源 | `https://github.com/radxa/u-boot` 分支 `rk3568-2023.10`（U-Boot v2023.10 基线） |
| u-boot 提交 | `cc60ff4058d8b84f762dd75190da2a8d5bf45c85` |
| rkbin 源 | `https://github.com/rockchip-linux/rkbin`（稀疏取 `bin/rk35`） |
| rkbin 提交 | `3e288fe814e059dd06833495f845cab04ac20a5c` |
| defconfig | `generic-rk3568_defconfig`（console=uart2=K1 的 ttyS2；含 sdhci/sdmmc0） |
| DDR 初始化固件 | `bin/rk35/rk3568_ddr_1560MHz_v1.26.bin`  sha256 `acb4e054298f0f0c8471dd3d45de07a1c77b67e687ec6e77ede365a087f1d95a` |
| DDR 版本串 | `DDR 5c7dbc4d49 kwin.chen 26/05/21-10:58:25,fwver: v1.26` |
| BL31 (TF-A) | `bin/rk35/rk3568_bl31_v1.46.elf`  sha256 `c81ac7e8e1fd727cf7f0db62a9aaea760bde2b270e34d98eb264a264b86df749` |
| 交叉编译器 | `aarch64-linux-gnu-gcc` |

> K1 实机 LPDDR4 `freq_0 = <0x618>` = **1560 MHz**；固件频率由文件名（`1560MHz`）决定，
> 脚本据此 + sha256 钉死 + 黑名单（兄弟板 T68M 的 `f366f69a7d`/`V1.18`）三重防呆。

## 产物（本次构建）

| 文件 | 大小(字节) | sha256 | 烧写位置 |
|------|-----------|--------|----------|
| `idbloader.img` | 176128 | `be04fe0d672a28ac55993f00a8b554f8f193fc6d5c28ea502a9954f224c37abf` | LBA 64（`bs=512 seek=64`） |
| `u-boot.itb` | 887296 | `6bd1e480bea8add9b446d6ce5084348cfde055964555702f65e0bc25469afa9d` | LBA 16384（`bs=512 seek=16384`） |

`u-boot.itb` 为 FIT：`U-Boot`(AArch64, load 0xa00000) + BL31(split-elf atf-1..6) + `fdt-rk3568-generic`。

> 注：idbloader 内嵌的 SPL 带 u-boot 构建日期字符串，故两次构建的 sha256 不会逐字节相同；
> **但内嵌 DDR 固件恒为上面那块 1560MHz v1.26**（脚本用偏移 2048 处的逐字节比对来保证）。

## 复现

```bash
# 默认：源/版本/输出目录全部内置
./build-uboot.sh

# CI 用法（workflow 中的调用形式）
./build-uboot.sh --out uboot-out

# 覆盖参数
./build-uboot.sh --work /tmp/ub --out /tmp/out --jobs 8 \
                 --ddr bin/rk35/rk3568_ddr_1560MHz_v1.26.bin \
                 --bl31 bin/rk35/rk3568_bl31_v1.46.elf
```

依赖：`aarch64-linux-gnu-gcc make git bc bison flex swig device-tree-compiler file`
及带 `pyelftools` 的 `python3`（缺失时脚本会尽力自助 `apt` 安装）。
