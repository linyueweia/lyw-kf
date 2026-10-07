#!/usr/bin/env bash
# 稳健版分段下载：用 Content-Range 探测总大小（HEAD 常被 CDN 掐），
# 每段可续传、大小自校验，全部齐了才拼装。可反复运行。
set -u
URL="${1:?usage: fetch-parallel2.sh <url> <out> [jobs]}"
OUT="${2:?}"
JOBS="${3:-8}"
TMP="$(dirname "$OUT")/.parts-$(basename "$OUT")"
mkdir -p "$TMP"

# ── 探总大小：优先 Content-Range，回退 HEAD ──
TOTAL=""
for try in 1 2 3 4 5; do
    TOTAL="$(curl -sfL --max-time 45 -r 0-0 -D - -o /dev/null "$URL" 2>/dev/null \
             | tr -d '\r' | awk 'BEGIN{IGNORECASE=1}/^content-range:/{split($0,a,"/");print a[2]}' | tail -1)"
    [[ "$TOTAL" =~ ^[0-9]+$ && "$TOTAL" -gt 1000000 ]] && break
    echo "  探测总大小第 $try 次失败，重试…"
    sleep 5
done
if [[ ! "$TOTAL" =~ ^[0-9]+$ || "$TOTAL" -lt 1000000 ]]; then
    echo "✗ 无法确定总大小（网络到 CDN 太差）。已下部分保留在 $TMP，可稍后重跑本脚本续传。"
    exit 1
fi
echo "  总大小: $TOTAL 字节 ($((TOTAL/1048576)) MB)，分 $JOBS 段"

CHUNK=$(( TOTAL / JOBS + 1 ))
declare -a WANT
for i in $(seq 0 $((JOBS-1))); do
    S=$(( i * CHUNK )); E=$(( S + CHUNK - 1 ))
    [[ $E -ge $TOTAL ]] && E=$(( TOTAL - 1 ))
    [[ $S -gt $E ]] && WANT[$i]=0 || WANT[$i]=$(( E - S + 1 ))
done

fetch_part() {  # $1=index  $2=start  $3=end  $4=want
    local i="$1" s="$2" e="$3" want="$4" f="$TMP/part.$i" have=0
    [[ -f "$f" ]] && have=$(stat -c%s "$f")
    if [[ "$have" -eq "$want" ]]; then echo "    段$i 已完整（跳过）"; return 0; fi
    # 断点续传
    for t in 1 2 3; do
        curl -sfL --retry 3 --retry-delay 3 -C - -r "$((s+have))-$e" -o "$f" "$URL" && {
            local now; now=$(stat -c%s "$f" 2>/dev/null || echo 0)
            [[ "$now" -eq "$want" ]] && { echo "    段$i 完成 $((now/1048576))MB"; return 0; }
        }
        sleep 4
    done
    echo "    段$i 未完成（$(stat -c%s "$f" 2>/dev/null || echo 0)/$want）"
    return 1
}

pids=(); idx=0
for i in $(seq 0 $((JOBS-1))); do
    [[ "${WANT[$i]}" -eq 0 ]] && continue
    S=$(( i * CHUNK )); E=$(( S + CHUNK - 1 )); [[ $E -ge $TOTAL ]] && E=$(( TOTAL - 1 ))
    fetch_part "$i" "$S" "$E" "${WANT[$i]}" &
    pids+=($!)
    idx=$((idx+1))
    # 控制并发
    if [[ $((idx % 6)) -eq 0 ]]; then wait; fi
done
wait

# ── 校验所有段完整 ──
missing=0
for i in $(seq 0 $((JOBS-1))); do
    [[ "${WANT[$i]}" -eq 0 ]] && continue
    f="$TMP/part.$i"
    sz=$(stat -c%s "$f" 2>/dev/null || echo 0)
    [[ "$sz" -eq "${WANT[$i]}" ]] || { echo "  ✗ 段$i 不完整 $sz/${WANT[$i]}"; missing=1; }
done
if [[ $missing -eq 1 ]]; then
    echo "⚠ 有段未齐，未拼装。重跑本脚本可续传。"
    exit 1
fi

echo "  全部段就绪，拼装中…"
: > "$OUT"
for i in $(seq 0 $((JOBS-1))); do cat "$TMP/part.$i" >> "$OUT"; done
sz=$(stat -c%s "$OUT")
if [[ "$sz" -eq "$TOTAL" ]]; then
    echo "  ✅ 拼装完成: $OUT ($sz 字节)"
    if [[ "$OUT" == *.gz ]]; then
        gzip -t "$OUT" 2>/dev/null && { echo "  ✅ gzip 校验通过"; rm -rf "$TMP"; } || echo "  ✗ gzip 校验失败"
    else
        rm -rf "$TMP"
    fi
else
    echo "  ✗ 拼装大小不符（$sz vs $TOTAL）"
    exit 1
fi
