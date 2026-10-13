#!/bin/sh
# KICKPI K1 (fnOS)：关闭网卡 EEE/LPI 省电 —— LPI 唤醒失败导致链路间歇 Down。
#
# 实机证据（2026-10-13，K1 两端 = 主路由 iNextOSA ↔ 本机 fnOS）：
#   · 对端 phy_eee_wakeup_error_n=8126、LPI 进出 7800 万次
#   · eth1 高峰时段（18:28–21:45）密集 Link Down 34 次/3h，深夜停网几乎不掉
#   · 两端 CRC/误码全 0（排除物理层）、温度 37°C（排除过热）
#   · ethtool --set-eee … eee off 后掉线归零
# 病理：EEE/LPI 省电态唤醒时序在 RK3568 dwmac + RTL8211F 上翻车 → 整口重协商。
# 与 PORTING.md §3 的五层坑是两个独立的病：那五层修"丢包"，这一层修"掉线"。
#
# 对镜像内每个真实网卡执行 --set-eee eee off 并把运行时电源管理钉死为 on；
# 带重试（PHY/接口可能尚未就绪）。不支持 EEE 的口（wifi/虚拟口）自动跳过。

ETHTOOL="$(command -v ethtool 2>/dev/null || echo /usr/sbin/ethtool)"
[ -x "$ETHTOOL" ] || { echo "kickpi-k1-eee-off: ethtool missing"; exit 1; }

attempt=0
while [ "$attempt" -lt 15 ]; do
	attempt=$((attempt + 1))
	pending=0
	for d in /sys/class/net/*; do
		[ -e "$d" ] || continue
		nic=${d##*/}
		case "$nic" in
			lo|docker*|veth*|br-*|virbr*|wg*|tailscale*|tun*|p2p*) continue ;;
		esac
		if ! "$ETHTOOL" --set-eee "$nic" eee off 2>/dev/null; then
			# set 失败：该口若根本支持不了 EEE（--show-eee 也失败）就不算欠账
			if "$ETHTOOL" --show-eee "$nic" >/dev/null 2>&1; then
				pending=1
			fi
		fi
		pm="$d/device/power/control"
		if [ -w "$pm" ]; then
			echo on > "$pm" 2>/dev/null || true
		fi
	done
	[ "$pending" -eq 0 ] && break
	sleep 2
done
echo "kickpi-k1-eee-off: done (attempt=$attempt)"
exit 0
