# maxio.ko 构建配方（已在实机验证通过）

目标内核：fnOS 6.18.18-trim（rockchip）
产物：maxio.ko，898432 字节，vermagic=6.18.18-trim SMP preempt mod_unload aarch64

## 依赖
- 飞牛内核 header 包：ophub/fnnas release kernel_fnnas -> 6.18.18-rockchip.tar.gz
  内含 header-rockchip-6.18.18-trim.tar.gz（完整内核树：Makefile/Module.symvers/include/scripts/arch）
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
insmod maxio.ko && dmesg | grep -i maxio
ethtool eth0 | grep -E "Speed|Duplex|Link detected"
