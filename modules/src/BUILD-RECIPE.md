# maxio.ko 构建配方（已在实机验证通过）

目标内核：**fnOS 基镜像内核 `6.18.18.c951-trim`**（release 必须从基镜像 rootfs 的
`/usr/lib/modules/<release>` 或 BOOT 分区 `config-<release>` 取，不是社区包名）
产物：maxio.ko，vermagic 必须包含 `6.18.18.c951-trim`

> ⚠ 别用社区包 `header-rockchip-6.18.18-trim`：它编出的 vermagic 是
> `6.18.18-trim SMP preempt mod_unload aarch64`，与基镜像 release 差一个 `.c951` 后缀，
> 装机 `insmod/modprobe` 会直接被 vermagic 比对拒掉（本仓库早期提交的预编 .ko 正是这个
> 命运，已移除）。`build-modules.sh` 会从基镜像里解 header 现编并逐个校验。

## 依赖
- 首选：**基镜像自带 header** `/usr/src/linux-headers-6.18.18.c951-trim`
  （由 `build-modules.sh` 自动解出并修好 .config / 主机工具 / autoconf.h）
- 备选：ophub/fnnas release kernel_fnnas -> 6.18.18-rockchip.tar.gz 的
  `header-rockchip-6.18.18-trim.tar.gz` —— 只能当**源码来源**，release 对不上，产物不可装机
- 本机 arm64（原生编译）或 aarch64 交叉工具链

## 已知坑（全部已绕过）
1. header 包缺 .config       -> cp include/config/auto.conf .config
2. header 包自带的主机工具是 arm64 且需 glibc>=2.33 -> 删掉 scripts/{basic/fixdep,mod/modpost,...} 重编
   - fixdep: 直接 make scripts（需 .config 已存在）
   - modpost: gcc -O2 -o scripts/mod/modpost scripts/mod/{modpost,file2alias,sumversion,symsearch}.c -Iscripts/mod -Iscripts/include -lelf
     （注意：不要加 -Iinclude，会撞内核头；缺 symsearch.c 会报 symsearch_* undefined）
3. 老编译器不认 -ftrivial-auto-var-init=zero -> 命令行置空 CONFIG_INIT_STACK_ALL_ZERO=
   （GCC12+ 环境无需此绕法）

## 命令
make -C <header根> M=<本目录> ARCH=arm64 CONFIG_INIT_STACK_ALL_ZERO= modules

## 加载验证（上机后）
insmod /usr/lib/modules/$(uname -r)/updates/kickpi-k1/maxio.ko && dmesg | grep -i maxio
modinfo maxio | grep vermagic          # 必须含 uname -r 的完整 release
ethtool end0 | grep -E "Speed|Duplex|Link detected"

## 验收日志门（缺一即未通过）
0 × `Cannot register the MDIO bus`（复位双持有 -EBUSY，板上相位A 实测 ×16）
0 × `probe with driver rk_gmac-dwmac failed`
`end0`/`end1` 驱动 = `rk_gmac-dwmac`，`phy_id` = `0x7b744411`
0 × `Failed to reset the dma`，且出现 `Link is Up`
