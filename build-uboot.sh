#!/usr/bin/env bash
# =============================================================================
# build-uboot.sh — 为 KICKPI K1（RK3568B2 / LPDDR4 @1560MHz）自构建 u-boot 引导件
# =============================================================================
#
# 产出（写入 OUT_DIR，默认 repo/uboot/rk3568/kickpi-k1/）：
#   idbloader.img   —— 写 LBA 64    (dd bs=512 seek=64)
#   u-boot.itb      —— 写 LBA 16384 (dd bs=512 seek=16384)
#
# 方案：直接用 radxa/u-boot + rockchip-linux/rkbin，不依赖 armbian 框架。
#   在 RK3568 上 CONFIG_ROCKCHIP_EXTERNAL_TPL 默认 y，因此
#       make CROSS_COMPILE=... BL31=<bl31.elf> ROCKCHIP_TPL=<ddr.bin>
#   binman 会把【外部 DDR 初始化固件】作为 TPL 塞进 idbloader.img，
#   把 BL31(TF-A) + u-boot-nodtb + 板级 dtb 合成 u-boot.itb(FIT)。
#
# 【DDR 频率防呆，核心纪律】—— K1 实机 LPDDR4 freq_0=0x618=1560MHz：
#   1) DDR 固件文件名必须命中 rk3568_ddr_1560MHz_*.bin（频率即由固件变体决定）
#   2) 抠出的固件版本串不得出现黑名单（V1.18 / f366f69a7d —— 兄弟板 T68M 的）
#   3) 可选 sha256 钉死（EXPECTED_DDR_SHA256）
#   4) 构建后从 idbloader.img 偏移 2048 处取回内嵌固件，要求 sha256 与源文件逐字节一致
#   任一条不过 -> 立即非零退出，绝不出货。
#
# 依赖：aarch64-linux-gnu-gcc、make、git、bc、bison、flex、swig、
#       python3(+pyelftools, setuptools)、dtc。（缺失时给出 apt 提示）
#
# 用法：
#   ./build-uboot.sh                 # 全默认
#   WORK_DIR=/tmp/ub DDR_FILE=bin/rk35/rk3568_ddr_1560MHz_v1.26.bin ./build-uboot.sh
# 可复现（全部可经环境变量覆盖）：
#   UBOOT_SRC UBOOT_BRANCH UBOOT_COMMIT  RKBIN_SRC RKBIN_COMMIT
#   DDR_FILE BL31_FILE DEFCONFIG CROSS_COMPILE JOBS
#   WORK_DIR OUT_DIR EXPECTED_DDR_SHA256
# =============================================================================
set -euo pipefail

# ---------- 路径 ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"        # repo/
REPO_DIR="$SCRIPT_DIR"
WORK_DIR="${WORK_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)/build-uboot}" # /work/kk/fnos/build-uboot
OUT_DIR="${OUT_DIR:-$REPO_DIR/uboot/rk3568/kickpi-k1}"

UBOOT_DIR="$WORK_DIR/uboot-radxa"
RKBIN_DIR="$WORK_DIR/rkbin"

# ---------- 源/版本（默认=本板已实测通过的一套） ----------
UBOOT_SRC="${UBOOT_SRC:-https://github.com/radxa/u-boot}"
UBOOT_BRANCH="${UBOOT_BRANCH:-rk3568-2023.10}"          # U-Boot v2023.10 基线的 rockchip 分支
UBOOT_COMMIT="${UBOOT_COMMIT:-cc60ff4058d8b84f762dd75190da2a8d5bf45c85}"

RKBIN_SRC="${RKBIN_SRC:-https://github.com/rockchip-linux/rkbin}"
RKBIN_COMMIT="${RKBIN_COMMIT:-3e288fe814e059dd06833495f845cab04ac20a5c}"

DEFCONFIG="${DEFCONFIG:-generic-rk3568_defconfig}"      # 纯 SoC 通用（console=uart2=K1 的 ttyS2）
CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}"
JOBS="${JOBS:-$(nproc)}"

# DDR 初始化固件（必须 1560MHz 系列！）
DDR_FILE="${DDR_FILE:-bin/rk35/rk3568_ddr_1560MHz_v1.26.bin}"
# 对应 1560MHz 的 BL31（TF-A）
BL31_FILE="${BL31_FILE:-bin/rk35/rk3568_bl31_v1.46.elf}"

# 已实测的 1560MHz v1.26 固件 sha256（换版本时清空或改此值）
EXPECTED_DDR_SHA256="${EXPECTED_DDR_SHA256-acb4e054298f0f0c8471dd3d45de07a1c77b67e687ec6e77ede365a087f1d95a}"
# 黑名单：兄弟板 T68M 的 DDR 固件（跨板复用是已验证的坑）
DDR_BLACKLIST_RE='f366f69a7d|v1\.18'

# ---------- 小工具 ----------
log()  { printf '\033[1;34m[build-uboot]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  ✓\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "缺少命令 '$1'（apt-get install $2）"; }

# ---------- 0. 依赖检查 ----------
check_deps() {
    log "0/6 检查依赖"
    need git git
    need make make
    need "${CROSS_COMPILE}gcc" gcc-aarch64-linux-gnu
    need bc bc
    need bison bison
    need flex flex
    need swig swig
    need dtc device-tree-compiler
    need file file
    # python3：binman 需要 pyelftools + setuptools；PATH 里第一个未必可用，自动挑一个
    local p found=""
    for p in "${PYTHON:-}" python3 /usr/bin/python3; do
        [ -n "$p" ] || continue
        if command -v "$p" >/dev/null 2>&1 \
           && "$p" -c 'import elftools, setuptools' >/dev/null 2>&1; then
            found="$(command -v "$p")"; break
        fi
    done
    if [ -z "$found" ]; then
        # 常见缺失：python3-pyelftools（binman 解析 BL31 ELF 必须）。尽最大努力自助安装。
        log "  缺少 pyelftools/setuptools，尝试自助安装…"
        if [ "$(id -u)" = 0 ]; then
            apt-get install -y -qq python3-pyelftools python3-setuptools >/dev/null 2>&1 || true
        elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
            sudo -n apt-get install -y -qq python3-pyelftools python3-setuptools >/dev/null 2>&1 || true
        fi
        for p in "${PYTHON:-}" python3 /usr/bin/python3; do
            [ -n "$p" ] || continue
            if command -v "$p" >/dev/null 2>&1 \
               && "$p" -c 'import elftools, setuptools' >/dev/null 2>&1; then
                found="$(command -v "$p")"; break
            fi
        done
    fi
    [ -n "$found" ] || die "找不到带 pyelftools/setuptools 的 python3（请 apt-get install python3-pyelftools python3-setuptools）"
    export PYTHON="$found" PYTHON3="$found"
    # 让 make 内部调用的 python3 也走这个解释器
    export PATH="$(dirname "$found"):$PATH"
    ok "python3 = $found ($("$found" --version 2>&1))"
    ok "交叉编译器 = $(command -v "${CROSS_COMPILE}gcc")"
}

# ---------- 1. 拉取 rkbin（稀疏，只要 bin/rk35） ----------
fetch_rkbin() {
    log "1/6 拉取 rkbin（稀疏取 bin/rk35）"
    if [ ! -d "$RKBIN_DIR/.git" ]; then
        mkdir -p "$RKBIN_DIR"
        git -C "$RKBIN_DIR" init -q
        git -C "$RKBIN_DIR" remote add origin "$RKBIN_SRC" 2>/dev/null || \
            git -C "$RKBIN_DIR" remote set-url origin "$RKBIN_SRC"
        git -C "$RKBIN_DIR" config core.sparseCheckout true
        git -C "$RKBIN_DIR" sparse-checkout init --cone
        git -C "$RKBIN_DIR" sparse-checkout set bin/rk35
    fi
    git -C "$RKBIN_DIR" fetch -q --depth 1 origin "$RKBIN_COMMIT"
    git -C "$RKBIN_DIR" checkout -q FETCH_HEAD
    ok "rkbin @ $(git -C "$RKBIN_DIR" rev-parse HEAD)"
}

# ---------- 2. 拉取 u-boot ----------
fetch_uboot() {
    log "2/6 拉取 u-boot（$UBOOT_BRANCH）"
    if [ ! -d "$UBOOT_DIR/.git" ]; then
        git clone -q --depth 1 --branch "$UBOOT_BRANCH" "$UBOOT_SRC" "$UBOOT_DIR"
    fi
    if git -C "$UBOOT_DIR" cat-file -e "$UBOOT_COMMIT^{commit}" 2>/dev/null; then
        git -C "$UBOOT_DIR" checkout -q "$UBOOT_COMMIT"
    else
        git -C "$UBOOT_DIR" fetch -q --depth 1 origin "$UBOOT_COMMIT" \
            || die "无法取得 u-boot 提交 $UBOOT_COMMIT"
        git -C "$UBOOT_DIR" checkout -q FETCH_HEAD
    fi
    ok "u-boot @ $(git -C "$UBOOT_DIR" rev-parse HEAD)"
}

# ---------- 3. DDR 防呆（构建前） ----------
DDR_ABS=""; BL31_ABS=""; DDR_FWVER=""; DDR_SHA=""
ddr_guard_pre() {
    log "3/6 DDR 固件防呆校验（必须 1560MHz 系列）"
    DDR_ABS="$RKBIN_DIR/$DDR_FILE"
    BL31_ABS="$RKBIN_DIR/$BL31_FILE"
    [ -f "$DDR_ABS" ] || die "DDR 固件不存在: $DDR_ABS"
    [ -f "$BL31_ABS" ] || die "BL31 不存在: $BL31_ABS"

    local base; base="$(basename "$DDR_ABS")"
    case "$base" in
        rk3568_ddr_1560MHz_v*.bin) : ;;
        *) die "DDR 固件不是 1560MHz 系列: $base（K1 实机 LPDDR4 freq_0=0x618=1560MHz）" ;;
    esac
    ok "频率文件命中 1560MHz: $base"

    # 先落盘再 grep，避免 `strings | grep -q` 在 set -o pipefail 下因 SIGPIPE 误判
    local dstr="$WORK_DIR/ddr.strings"
    strings "$DDR_ABS" > "$dstr"
    if grep -Eqi "$DDR_BLACKLIST_RE" "$dstr"; then
        grep -Ei "$DDR_BLACKLIST_RE" "$dstr" | head -1 | sed 's/^/    命中黑名单: /'
        die "DDR 固件命中黑名单（$DDR_BLACKLIST_RE）—— 疑似兄弟板 T68M 的固件，拒绝使用"
    fi
    DDR_FWVER="$(grep -oiE 'fwver: v[0-9]+\.[0-9]+' "$dstr" | head -1 || true)"
    [ -n "$DDR_FWVER" ] || die "无法从 $base 抠出 fwver 版本串，固件可疑"
    ok "DDR 版本串: $DDR_FWVER"

    DDR_SHA="$(sha256sum "$DDR_ABS" | awk '{print $1}')"
    if [ -n "$EXPECTED_DDR_SHA256" ]; then
        [ "$DDR_SHA" = "$EXPECTED_DDR_SHA256" ] \
            || die "DDR 固件 sha256 不匹配: 期望 $EXPECTED_DDR_SHA256 / 实得 $DDR_SHA（换版本请显式覆盖 EXPECTED_DDR_SHA256）"
        ok "DDR sha256 已钉死: ${DDR_SHA:0:16}…"
    fi
    ok "BL31: $(basename "$BL31_ABS") sha256=$(sha256sum "$BL31_ABS" | awk '{print $1}' | cut -c1-16)…"
}

# ---------- 4. 构建 ----------
build_uboot() {
    log "4/6 构建（$DEFCONFIG, -j$JOBS）"
    local mk=(make -C "$UBOOT_DIR" -j"$JOBS" CROSS_COMPILE="$CROSS_COMPILE")
    ( cd "$UBOOT_DIR" && make distclean >/dev/null 2>&1 || true )
    ( cd "$UBOOT_DIR" && make "$DEFCONFIG" >/dev/null )
    ( cd "$UBOOT_DIR" && "${mk[@]}" BL31="$BL31_ABS" ROCKCHIP_TPL="$DDR_ABS" >"$WORK_DIR/build.log" 2>&1 ) \
        || { tail -30 "$WORK_DIR/build.log"; die "u-boot 构建失败（日志 $WORK_DIR/build.log）"; }
    for f in idbloader.img u-boot.itb; do
        [ -f "$UBOOT_DIR/$f" ] || die "构建结束但缺少 $f（见 $WORK_DIR/build.log）"
    done
    ok "构建成功"
}

# ---------- 5. 构建后校验 ----------
post_guard() {
    log "5/6 产物校验"
    local idb="$UBOOT_DIR/idbloader.img" itb="$UBOOT_DIR/u-boot.itb"
    local istr="$WORK_DIR/idb.strings" tstr="$WORK_DIR/itb.strings"
    strings "$idb" > "$istr"
    strings "$itb" > "$tstr"

    # 5a. idbloader 里必须出现 1560 系列的 DDR 版本串，且不得命中黑名单
    if grep -Eqi "$DDR_BLACKLIST_RE" "$istr"; then
        die "idbloader.img 命中 DDR 黑名单（$DDR_BLACKLIST_RE）！"
    fi
    grep -qi 'fwver: v[0-9]' "$istr" || die "idbloader.img 里找不到 DDR fwver 版本串"
    grep -qi "$DDR_FWVER"    "$istr" || die "idbloader.img 里的 DDR 版本串与源固件($DDR_FWVER)不一致"
    ok "idbloader DDR 版本串与源固件一致: $DDR_FWVER"

    # 5b. 逐字节确认 idbloader 内嵌的就是我们校验过的那块 1560MHz 固件
    #     rksd 布局: [2048B header][DDR 固件][SPL]
    local ddr_size embedded
    ddr_size="$(stat -c%s "$DDR_ABS")"
    embedded="$(dd if="$idb" bs=1 skip=2048 count="$ddr_size" 2>/dev/null | sha256sum | awk '{print $1}')"
    [ "$embedded" = "$DDR_SHA" ] \
        || die "idbloader 内嵌 DDR 固件与源文件不一致（内嵌 ${embedded:0:16}… ≠ 源 ${DDR_SHA:0:16}…）"
    ok "idbloader 内嵌 DDR 固件与源文件逐字节一致（${embedded:0:16}…）"

    # 5c. u-boot.itb 必须是 FIT，且含 u-boot 与 bl31
    file "$itb" | grep -qi 'Device Tree Blob\|Flattened Device Tree' \
        || die "u-boot.itb 不是 FIT/DTB 格式"
    grep -qi 'FIT image for U-Boot' "$tstr" || die "u-boot.itb 不是预期的 U-Boot FIT"
    grep -qi 'bl31-v'              "$tstr" || die "u-boot.itb 里没有 BL31(TF-A)"
    ok "u-boot.itb 为 FIT，含 U-Boot + BL31"
}

# ---------- 6. 安装产物 ----------
install_out() {
    log "6/6 安装产物 -> $OUT_DIR"
    mkdir -p "$OUT_DIR"
    install -m644 "$UBOOT_DIR/idbloader.img" "$OUT_DIR/idbloader.img"
    install -m644 "$UBOOT_DIR/u-boot.itb"    "$OUT_DIR/u-boot.itb"
    printf '\n===== 产物 =====\n'
    ( cd "$OUT_DIR" && ls -la idbloader.img u-boot.itb )
    ( cd "$OUT_DIR" && sha256sum idbloader.img u-boot.itb )
    printf '\n  idbloader.img -> LBA 64    : dd if=idbloader.img of=<dev> bs=512 seek=64\n'
    printf '  u-boot.itb    -> LBA 16384 : dd if=u-boot.itb    of=<dev> bs=512 seek=16384\n'
    printf '\n  u-boot : %s @ %s\n' "$UBOOT_BRANCH" "$(git -C "$UBOOT_DIR" rev-parse --short HEAD)"
    printf '  rkbin  : @ %s\n' "$(git -C "$RKBIN_DIR" rev-parse --short HEAD)"
    printf '  DDR    : %s  (%s)\n' "$(basename "$DDR_ABS")" "$DDR_FWVER"
    printf '  BL31   : %s\n' "$(basename "$BL31_ABS")"
}

# ---------- 参数 ----------
usage() {
    cat <<EOF
用法: $(basename "$0") [选项]
  --out DIR        产物输出目录        (默认 $OUT_DIR)
  --work DIR       构建/工作目录        (默认 $WORK_DIR)
  --jobs N         并行度              (默认 $(nproc))
  --ddr FILE       rkbin 内 DDR 固件相对路径 (默认 $DDR_FILE)
  --bl31 FILE      rkbin 内 BL31 相对路径     (默认 $BL31_FILE)
  --defconfig X    u-boot defconfig     (默认 $DEFCONFIG)
  -h, --help       显示本帮助
以上各项亦可用同名大写环境变量覆盖（OUT_DIR/WORK_DIR/JOBS/DDR_FILE/BL31_FILE/DEFCONFIG
/UBOOT_SRC/UBOOT_BRANCH/UBOOT_COMMIT/RKBIN_SRC/RKBIN_COMMIT/CROSS_COMPILE/EXPECTED_DDR_SHA256）。
EOF
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --out)        OUT_DIR="$2"; shift 2 ;;
            --out=*)      OUT_DIR="${1#*=}"; shift ;;
            --work)       WORK_DIR="$2"; shift 2 ;;
            --work=*)     WORK_DIR="${1#*=}"; shift ;;
            --jobs)       JOBS="$2"; shift 2 ;;
            --jobs=*)     JOBS="${1#*=}"; shift ;;
            --ddr)        DDR_FILE="$2"; shift 2 ;;
            --ddr=*)      DDR_FILE="${1#*=}"; shift ;;
            --bl31)       BL31_FILE="$2"; shift 2 ;;
            --bl31=*)     BL31_FILE="${1#*=}"; shift ;;
            --defconfig)  DEFCONFIG="$2"; shift 2 ;;
            --defconfig=*) DEFCONFIG="${1#*=}"; shift ;;
            -h|--help)    usage; exit 0 ;;
            *)            die "未知参数: $1（用 --help 查看用法）" ;;
        esac
    done
    # 派生目录（随 WORK_DIR 变化）
    UBOOT_DIR="$WORK_DIR/uboot-radxa"
    RKBIN_DIR="$WORK_DIR/rkbin"
}

main() {
    parse_args "$@"
    log "KICKPI K1 (RK3568B2) u-boot 自构建"
    log "WORK_DIR=$WORK_DIR  OUT_DIR=$OUT_DIR"
    mkdir -p "$WORK_DIR"
    check_deps
    fetch_rkbin
    fetch_uboot
    ddr_guard_pre
    build_uboot
    post_guard
    install_out
    log "完成 ✓"
}

main "$@"
