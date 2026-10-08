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

# 网口 DT 门禁（对提交的 dist DTB）
if [[ -f dist/rk3568-kickpi-k1.dtb ]]; then
    if bash tools/verify-k1-net-dts.sh dist/rk3568-kickpi-k1.dtb >/tmp/_rs_net.log 2>&1; then
        echo "  ✓ 网口 DT 门禁 ALL PASS（dist DTB）"
    else
        echo "  ✗ 网口 DT 门禁 FAIL（dist DTB）"; tail -12 /tmp/_rs_net.log | sed 's/^/     /'; FAIL=1
    fi
else
    echo "  ✗ dist/rk3568-kickpi-k1.dtb 缺失"; FAIL=1
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

# 预编 .ko 的 vermagic 必须与装配用的内核一致（否则本地 MODULES_DIR=modules 用法必然被硬闸 fail）
if [[ -f modules/maxio.ko ]]; then
    vm="$(strings modules/maxio.ko | grep -oE 'vermagic=[^\"]*' | head -1)"
    case "$vm" in
        *"c951-trim"*) echo "  ✓ modules/maxio.ko vermagic 与基镜像一致 ($vm)";;
        *) echo "  ✗ modules/maxio.ko vermagic 过期: $vm"; echo "     → 删除它或用 build-modules.sh 按基镜像 header 重编"; FAIL=1;;
    esac
fi

echo "------------------------------------------------"
[[ $FAIL -eq 0 ]] && echo "REPO STATIC GATE: ALL PASS" || echo "REPO STATIC GATE: FAIL"
exit $FAIL
