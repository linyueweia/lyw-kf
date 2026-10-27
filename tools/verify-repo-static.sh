#!/usr/bin/env bash
# 仓库静态门禁 —— 在【装配镜像之前】拦掉仓库内已知有害的材料。
# 判据来源：取证 A3/A5
#   ① uboot/rk3568/kickpi-k1/extlinux.conf 曾写 root=/dev/mmcblk0p2（本板 Android 布局的
#      厂商 eMMC 分区）→ 一旦被拷进 boot 分区就挂厂商系统；六环门禁按设计只扫镜像，拦不住仓库材料。
#   ② 同理不得出现厂商 eMMC PARTUUID 614e0000-0000-4b53-8000-1d28000054a9。
# 用法: tools/verify-repo-static.sh   （cwd = 仓库根）
set -u
FAIL=0
EMMC_UUID="614e0000-0000-4b53-8000-1d28000054a9"

echo "== 仓库静态门禁 =="
# 日志文件用私有临时目录（固定 /tmp 名在共享环境会撞权限/并发覆盖）
TMPD="$(mktemp -d "${TMPDIR:-/tmp}/kf-static.XXXXXX")" || { echo "✗ 建临时目录失败"; exit 1; }
trap 'rm -rf "$TMPD"' EXIT
# 只查会被装配/引导消费的材料，跳过 .git 与文档里的历史描述
SCAN_DIRS=(uboot tools dts patches assets .github)
for d in "${SCAN_DIRS[@]}"; do
    [[ -d "$d" ]] || continue
    SELF="$(readlink -f "${BASH_SOURCE[0]}")"
    while IFS= read -r f; do
        # 只判【真正会被消费的引用】：/dev/mmcblk0pN（注释里的 /dev/mmcblk0* 警示不算）
        [[ "$(readlink -f "$f")" == "$SELF" ]] && continue
        grep -qE '/dev/mmcblk0p[0-9]|root=[^ ]*mmcblk0' "$f" 2>/dev/null && {
            echo "  ✗ ${f} 含 /dev/mmcblk0pN（厂商 eMMC 劫持路径）"; FAIL=1; }
        grep -qi "$EMMC_UUID" "$f" 2>/dev/null && {
            echo "  ✗ ${f} 含厂商 eMMC PARTUUID"; FAIL=1; }
    done < <(find "$d" -type f \( -name '*.conf' -o -name '*.txt' -o -name '*.cfg' \
                                -o -name '*.sh' -o -name '*.yml' -o -name '*.yaml' \) )
done
[[ $FAIL -eq 0 ]] && echo "  ✓ 未发现 eMMC 劫持路径/厂商 PARTUUID"

# EEE 反向门禁（2026-10-17 改判）：EEE 按官方默认保持开启 ——
# 构建脚本与 assets 里都不得再出现 EEE 关闭件，且不得往镜像注入关闭服务/dispatcher。
# 只认"真的在装/在 enable"的写法，避免把反向断言里出现的文件名当命中。
if grep -qF 'install -Dm755 "$ASSETS/kickpi-k1-eee-off.sh"' build-k1-fnos.sh 2>/dev/null \
   || grep -qF 'ln -sf ../kickpi-k1-eee-off.service' build-k1-fnos.sh 2>/dev/null \
   || grep -qF 'install -Dm755 "$ASSETS/kickpi-k1-eee-dispatcher"' build-k1-fnos.sh 2>/dev/null \
   || [[ -f assets/kickpi-k1-eee-off.sh ]] \
   || [[ -f assets/kickpi-k1-eee-dispatcher ]]; then
    echo "  ✗ 仍存在 EEE 关闭件（kickpi-k1-eee-off / dispatcher）—— 与官方默认不一致"; FAIL=1
else
    echo "  ✓ 无 EEE 关闭件（按官方默认保持开启）"
fi

# 存量系统在线修复件（不必重刷镜像）+ 首启自愈单元
if [[ -x assets/fnos-fix-log-errors.sh || -f assets/fnos-fix-log-errors.sh ]] \
   && bash -n assets/fnos-fix-log-errors.sh 2>/dev/null \
   && grep -q 'fnos-fix-log-errors.service' build-k1-fnos.sh 2>/dev/null; then
    echo "  ✓ 存量系统修复件在位（fnos-fix-log-errors.sh + 首启自愈单元注入）"
else
    echo "  ✗ 存量系统修复件缺失或语法错误"; FAIL=1
fi

# 网口 DT 门禁（对提交的 dist DTB）
if [[ -f dist/rk3568-kickpi-k1.dtb ]]; then
    if bash tools/verify-k1-net-dts.sh dist/rk3568-kickpi-k1.dtb >"$TMPD/net.log" 2>&1; then
        echo "  ✓ 网口 DT 门禁 ALL PASS（dist DTB）"
    else
        echo "  ✗ 网口 DT 门禁 FAIL（dist DTB）"; tail -12 "$TMPD/net.log" | sed 's/^/     /'; FAIL=1
    fi
else
    echo "  ✗ dist/rk3568-kickpi-k1.dtb 缺失"; FAIL=1
fi

# 媒体层 DT 门禁（2026-10-19 转码死机事故防回归；判据=官方 fnOS RK3568 设备 DTB 对照）
if [[ -f dist/rk3568-kickpi-k1.dtb ]]; then
    if bash tools/verify-k1-media-dts.sh dist/rk3568-kickpi-k1.dtb >"$TMPD/media.log" 2>&1; then
        echo "  ✓ 媒体 DT 门禁 ALL PASS（dist DTB）"
    else
        echo "  ✗ 媒体 DT 门禁 FAIL（dist DTB）"; tail -20 "$TMPD/media.log" | sed 's/^/     /'; FAIL=1
    fi
fi

# 媒体簇对标官方 R5S（2026-10-27 用户口径：与官方 R5S 方案对齐，逐节点、逐属性）
if [[ -f dist/rk3568-kickpi-k1.dtb && -f dist/rk3568-nanopi-r5s-official.dtb ]]; then
    if python3 tools/r5s-media-parity.py dist/rk3568-kickpi-k1.dtb \
            dist/rk3568-nanopi-r5s-official.dtb >"$TMPD/parity.log" 2>&1; then
        echo "  ✓ 媒体簇与官方 R5S 逐节点一致（例外已登记 dts/r5s-media-allowlist.txt）"
    else
        echo "  ✗ 媒体簇与官方 R5S 不一致"; sed 's/^/     /' "$TMPD/parity.log" | tail -24; FAIL=1
    fi
else
    echo "  ✗ 缺 dist/rk3568-nanopi-r5s-official.dtb（官方 R5S 参照件，媒体簇对标的前提）"; FAIL=1
fi

# dist DTB 必须由 dts/ 源现编得出（防改了源忘了重编 DTB）
if [[ -f dts/rk3568-kickpi-k1.dts && -f dist/rk3568-kickpi-k1.dtb ]]; then
    T="$(mktemp -d)"
    if dtc -f -Wno-pci_device_reg -Wno-unit_address_vs_reg -I dts -O dtb \
        -o "$T/rebuilt.dtb" dts/rk3568-kickpi-k1.dts 2>"$T/dtc.log"; then
        if cmp -s "$T/rebuilt.dtb" dist/rk3568-kickpi-k1.dtb; then
            echo "  ✓ dist DTB 与 dts 源现编结果逐字节一致（$(stat -c%s dist/rk3568-kickpi-k1.dtb) B）"
        else
            echo "  ✗ dist DTB 与 dts 源不一致 → 忘了重编 DTB"; FAIL=1
        fi
    else
        echo "  ✗ dts 源编译失败："; tail -6 "$T/dtc.log" | sed 's/^/     /'; FAIL=1
    fi
    rm -rf "$T"
fi

# 预编 .ko 的 vermagic 必须是【官方基镜像内核】形态（6.18.x.cNNN-trim）。
# 旧写法写死 c951-trim —— 基镜像已升到 v1.1.0（c1145-trim），那种断言会在换成对版本后误杀。
if [[ -f modules/maxio.ko ]]; then
    vm="$(strings modules/maxio.ko | grep -oE 'vermagic=[^"]*' | head -1)"
    if [[ "$vm" =~ 6\.18\.[0-9]+\.c[0-9]+-trim ]]; then
        echo "  ✓ modules/maxio.ko vermagic 是官方基镜像口径 ($vm)"
    else
        echo "  ✗ modules/maxio.ko vermagic 不是官方基镜像口径: $vm"
        echo "     → 删掉它：.ko 一律由 build-modules.sh 按基镜像 header 现编"
        FAIL=1
    fi
fi

# 已废弃件不得回归（2026-10-27 仓库整理：自愈逻辑只留一套）
# 注意：只判【真正的调用/安装行】，注释里提到旧文件名不算（历史说明要保留）。
for f in assets/kickpi-k1-build-modules.sh modules/wifi-src.tar.gz.ORIGIN; do
    [[ -e "$f" ]] && { echo "  ✗ 已废弃件回归: $f（编译逻辑只用 modules/ota/modules-ensure.sh）"; FAIL=1; }
done
for f in build-k1-fnos.sh modules/ota/modules-ensure.sh assets/zz-kickpi-k1-modules; do
    if awk '/kickpi-k1-build-modules/ && $0 !~ /^[[:space:]]*#/ {found=1} END{exit !found}' "$f" 2>/dev/null; then
        echo "  ✗ $f 里仍在调用已废弃的 kickpi-k1-build-modules.sh"; FAIL=1
    fi
done
# 构建期不得依赖外网 clone（整理后源码随仓库 wifi-src.tar.gz 下发，离线可复现）
if awk '/git clone/ && $0 !~ /^[[:space:]]*#/ {found=1} END{exit !found}' build-k1-fnos.sh 2>/dev/null; then
    echo "  ✗ build-k1-fnos.sh 里有构建期 git clone（离线不可复现，源码应来自仓库）"; FAIL=1
fi
[[ $FAIL -eq 0 ]] && echo "  ✓ 无废弃件/无构建期联网依赖"

# 禁止固定 /tmp 文件名（共享 /tmp 上会撞属主/属性 → Permission denied；并发构建还会互相覆盖）
# 判据：脚本里出现 "/tmp/_xxx" 这类固定名（注释不算）即判红，必须改用 mktemp。
while IFS= read -r f; do
    if awk '/\/tmp\/_[A-Za-z0-9._]+/ && $0 !~ /^[[:space:]]*#/ {found=1} END{exit !found}' "$f"; then
        echo "  ✗ $f 用了固定 /tmp 文件名（改 mktemp；共享 /tmp 会撞权限）"; FAIL=1
    fi
done < <(git ls-files '*.sh' '*.py' 2>/dev/null | grep -v '^tools/offline-read/')
[[ $FAIL -eq 0 ]] && echo "  ✓ 无固定 /tmp 文件名"

# 文档与脚本一致性：README/文档里写的 ./xxx.sh 必须存在且带可执行位
# （本机是 Windows 提交的仓库，曾把 build-*.sh 提交成 100644 → 照文档 ./build-dtb.sh 必 Permission denied）
while IFS= read -r s; do
    [[ -f "$s" ]] || { echo "  ✗ 文档引用了不存在的脚本: $s"; FAIL=1; continue; }
    [[ -x "$s" ]] || { echo "  ✗ $s 缺可执行位（文档写 ./$s 会 Permission denied）"; FAIL=1; }
done < <(grep -rhoE '\./[A-Za-z0-9_./-]+\.sh' README.md PORTING.md TROUBLESHOOTING.md docs/ 2>/dev/null \
         | sed 's#^\./##' | sort -u)
[[ $FAIL -eq 0 ]] && echo "  ✓ 文档引用的脚本都存在且可执行"

echo "------------------------------------------------"
[[ $FAIL -eq 0 ]] && echo "REPO STATIC GATE: ALL PASS" || echo "REPO STATIC GATE: FAIL"
exit $FAIL
