#!/usr/bin/env bash
# build-k1-fnos.sh 的「引导参数硬门禁」单元测试（kernelfile 形态 + cma=256M）
#
# 为什么要有它：这两个门禁是"刷进去必黑"与"CMA 口径漂移"的唯一防线，而它们只在装配
# 真正挂载镜像时才会跑到 —— 全量构建 90 分钟，靠 CI 试错代价太大。本测试把门禁片段
# 从 build-k1-fnos.sh 里原样抽出来，用临时目录造 BOOT 分区，四类正例四类负例一次跑完。
#
# 用法: bash tools/tests/kf-boot-gate-test.sh [build-k1-fnos.sh]
# 本地（Windows/MSYS）注意：原生 python 不认 /c/、/tmp/，请设 KF_TEST_ROOT=C:/... 形式。
set -u
SRC="${1:-build-k1-fnos.sh}"
ROOT="${KF_TEST_ROOT:-${TMPDIR:-/tmp}}/kf-boot-gate-$$"
PY="${PYTHON:-python3}"

BEGIN='# ── 硬门禁 1'
END='# 历史构建残留/回退用的 extlinux.conf'
SNIP="$(awk -v b="$BEGIN" -v e="$END" 'index($0,b){f=1} f&&index($0,e){exit} f{print}' "$SRC")"
[[ -n "$SNIP" ]] || { echo "✗ 从 $SRC 抽不到门禁片段（$BEGIN … $END），脚本结构变了？"; exit 1; }
# 门禁里的"kernelfile 悬空自动纠正"会调 fnenv_set()，一起抽出来（保证测的是真实实现）
HELPER="$(awk '/^fnenv_set\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$SRC")"
[[ -n "$HELPER" ]] || { echo "✗ 从 $SRC 抽不到 fnenv_set()（脚本结构变了？）"; exit 1; }

mkdir -p "$ROOT" || { echo "✗ 建不了临时目录 $ROOT"; exit 1; }
trap 'rm -rf "$ROOT"' EXIT

run_case() {   # <名字> <期望 ok|fail> <准备函数>
    local name="$1" want="$2" setup="$3"
    local MNT="$ROOT/c$RANDOM$RANDOM"
    rm -rf "$MNT"; mkdir -p "$MNT"
    ( $setup "$MNT" ) || { echo "  ✗ $name 前置失败"; return 1; }
    local rc=0 out
    out="$( BOOT_MNT="$MNT"; fail(){ echo "FAILMSG:$*"; exit 9; }; eval "$HELPER"; eval "$SNIP" )" || rc=$?
    local got="ok"; [[ $rc -ne 0 ]] && got="fail"
    if [[ "$got" == "$want" ]]; then
        echo "  ✓ $name → $got"
        [[ $want == fail ]] && echo "      判死理由: $(echo "$out" | grep FAILMSG | head -1 | sed 's/FAILMSG://')"
        return 0
    fi
    echo "  ✗ $name → 期望 $want 实得 $got"; echo "$out" | sed 's/^/      /'
    return 1
}

mk_kernel() {   # <文件> <img|gzip|junk> [字节数]
    "$PY" - "$1" "$2" "${3:-8388608}" <<'PY'
import gzip, os, sys
p, kind, size = sys.argv[1], sys.argv[2], int(sys.argv[3])
if kind == 'img':                       # ARM64 Image：偏移 0x38 = "ARM\x64"
    data = bytearray(size); data[0x38:0x3c] = b'ARM\x64'; data[0] = 0x4d
elif kind == 'gzip':
    data = gzip.compress(os.urandom(max(6 * 1024 * 1024, size)))
else:
    data = bytearray(size)
open(p, 'wb').write(bytes(data))
PY
}

s_ok()      { printf 'verbosity=1\nkernelfile=vmlinuz-6.18.18.c1145-trim\nextraargs=cma=256M\n' > "$1/fnEnv.txt"; mk_kernel "$1/vmlinuz-6.18.18.c1145-trim" img; }
s_gzip()    { printf 'kernelfile=vmlinuz\nextraargs=cma=256M\n' > "$1/fnEnv.txt"; mk_kernel "$1/vmlinuz-real" gzip; ln -s vmlinuz-real "$1/vmlinuz"; }
s_nokf()    { printf 'verbosity=1\nextraargs=cma=256M\n' > "$1/fnEnv.txt"; mk_kernel "$1/vmlinuz-6.18.18.c1145-trim" img; }
s_dangling(){ printf 'kernelfile=vmlinuz-6.18.18.c951-trim\nextraargs=cma=256M\n' > "$1/fnEnv.txt"; mk_kernel "$1/vmlinuz-6.18.18.c1145-trim" img; }
s_small()   { printf 'kernelfile=vmlinuz\nextraargs=cma=256M\n' > "$1/fnEnv.txt"; mk_kernel "$1/vmlinuz" img 1024; }
s_junk()    { printf 'kernelfile=vmlinuz\nextraargs=cma=256M\n' > "$1/fnEnv.txt"; mk_kernel "$1/vmlinuz" junk; }
s_cma1g()   { printf 'kernelfile=vmlinuz\nextraargs=cma=1G loglevel=7\n' > "$1/fnEnv.txt"; mk_kernel "$1/vmlinuz" img; }
s_cma2g()   { printf 'kernelfile=vmlinuz\nextraargs=cma=2G\n' > "$1/fnEnv.txt"; mk_kernel "$1/vmlinuz" img; }
s_nokernel(){ printf 'kernelfile=vmlinuz-x\nextraargs=cma=256M\n' > "$1/fnEnv.txt"; }
# 2026-10-27 新增：产品口径的 extraargs 只能是 cma=256M ——
# 历史上 "cma=256M loglevel=7 ignore_loglevel" 被当成合法（旧门禁只 grep cma=256M），
# 结果它随镜像发布、开机全程刷屏。这条负例锁死"不得夹带调试参数"。
s_dbg()     { printf 'kernelfile=vmlinuz\nextraargs=cma=256M loglevel=7 ignore_loglevel\n' > "$1/fnEnv.txt"; mk_kernel "$1/vmlinuz" img; }

echo "== 引导参数硬门禁单元测试（$SRC）"
F=0
run_case "合法 arm64 Image + cma=256M"        ok   s_ok       || F=$((F+1))
run_case "合法 gzip + 软链 vmlinuz"            ok   s_gzip     || F=$((F+1))
run_case "缺 kernelfile → 自动补齐"            ok   s_nokf     || F=$((F+1))
run_case "kernelfile 悬空 → 自动纠正"          ok   s_dangling || F=$((F+1))
run_case "内核 <5MB → 判死"                    fail s_small    || F=$((F+1))
run_case "内容不是内核 → 判死"                 fail s_junk     || F=$((F+1))
run_case "cma=1G（历史回退）→ 判死"            fail s_cma1g    || F=$((F+1))
run_case "cma=2G → 判死"                       fail s_cma2g    || F=$((F+1))
run_case "分区里没有任何内核 → 判死"            fail s_nokernel || F=$((F+1))
run_case "extraargs 夹带 loglevel=7 → 判死"     fail s_dbg      || F=$((F+1))
TOTAL=10
if [[ $F -eq 0 ]]; then echo "结果: $TOTAL/$TOTAL 通过"; else echo "结果: $((TOTAL-F))/$TOTAL 通过（$F 例未过）"; fi
exit $F
