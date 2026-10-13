#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════
# 飞牛(fnOS / KICKPI K1) —— 存量系统日志错误修复（在线跑，幂等）
#
# 用途：把【已经在跑的】飞牛系统按本仓（lyw-kf）已定的决策修一遍，
#       不必重刷镜像。全部改动可回滚（备份在 /root/fnos-fix-backup-<时间戳>）。
#
# 依据（2026-10-13/14 实机日志取证，/root/fnos-logs-* 与桌面导出包）：
#   真故障：
#     1) 网口 EEE 被重新打开 —— `ethtool --show-eee end0/end1` = enabled，
#        而 net-nosleep.service 已 enabled+active（它只管 power/control，不管 EEE）。
#        → 装三层持久件（脚本 + 开机服务 + NM dispatcher），判据：全部 disabled。
#     2) exim4.service failed —— 未配置的 MTA，日志目录都打不开
#        （Cannot open main log file "/var/log/exim4/mainlog": Permission denied）。
#        本仓决策 = mask（见 build-k1-fnos.sh (3) 段：exim4 = 未配置）。
#     3) pwm-fancontrol.service failed —— `No fan configuration found in /boot/board.json`；
#        本板风扇由内核 gpio-fan 管，本仓决策 = mask（同上 (3) 段）。
#     4) webdav.service 每次启动告警 "marked executable" → chmod 644。
#     5) 每次启动还报 networking.service（ifupdown 残留）→ 本仓决策 = mask。
#   良性噪声（**不要改**，改了反而误事）：见文件末尾白名单。
#
# 用法（飞牛上，root）：  sudo bash fnos-fix-log-errors.sh
# ══════════════════════════════════════════════════════════════════════════
set -u
TS=$(date +%Y%m%d-%H%M%S)
BK="/root/fnos-fix-backup-$TS"
mkdir -p "$BK"
say(){ printf '\n\033[1;36m== %s\033[0m\n' "$*"; }
ok(){  printf '  ✓ %s\n' "$*"; }
bad(){ printf '  ✗ %s\n' "$*"; }

say "0) 备份现场到 $BK"
for f in /etc/systemd/system/net-nosleep.service /etc/systemd/system/webdav.service /boot/board.json; do
	[ -e "$f" ] && cp -a "$f" "$BK/" 2>/dev/null
done
systemctl --failed --no-pager > "$BK/units-failed-before.txt" 2>&1 || true
for n in end0 end1 eth0 eth1; do
	[ -e "/sys/class/net/$n" ] && ethtool --show-eee "$n" 2>/dev/null > "$BK/eee-$n-before.txt"
done
ok "已备份（含修复前 failed 单元与 EEE 状态）"

# ── 1) EEE/LPI 三层持久化 ────────────────────────────────────────────────
say "1) 关掉所有网口 EEE/LPI（脚本 + 开机服务 + NM dispatcher）"
cat > /usr/local/sbin/kickpi-k1-eee-off.sh <<'EOF'
#!/bin/sh
# KICKPI K1：关闭所有真实网卡的 EEE/LPI 省电，并把运行时电源管理钉为 on。
# 为什么：EEE 唤醒时序在本板 RK3568 dwmac + Maxio MAE0621A 上翻车 → 整口间歇 Link Down
# （实机判据：对端 phy_eee_wakeup_error_n=8126、LPI 进出 7800 万次；关上后掉线归零）。
# 幂等：可反复执行（开机一次 + 每次接口 up 一次 + 人工随时跑）。
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
			if "$ETHTOOL" --show-eee "$nic" >/dev/null 2>&1; then pending=1; fi
		fi
		pm="$d/device/power/control"
		if [ -w "$pm" ]; then echo on > "$pm" 2>/dev/null || true; fi
	done
	[ "$pending" -eq 0 ] && break
	sleep 2
done
echo "kickpi-k1-eee-off: done (attempt=$attempt)"
exit 0
EOF
chmod 0755 /usr/local/sbin/kickpi-k1-eee-off.sh

cat > /etc/systemd/system/kickpi-k1-eee-off.service <<'EOF'
[Unit]
Description=fnOS(KICKPI K1): disable NIC EEE/LPI (link-stability fix)
After=NetworkManager.service network-online.target
Wants=network-online.target
ConditionPathExists=/usr/local/sbin/kickpi-k1-eee-off.sh

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh /usr/local/sbin/kickpi-k1-eee-off.sh
TimeoutStartSec=60

[Install]
WantedBy=multi-user.target
EOF

mkdir -p /etc/NetworkManager/dispatcher.d
cat > /etc/NetworkManager/dispatcher.d/90-kickpi-k1-eee-off <<'EOF'
#!/bin/sh
# NM 每次接口状态变化都调一次：EEE 会随重新协商被打开，只在开机关一次守不住。
IFACE="$1"
ACTION="$2"
case "$ACTION" in
	up|dhcp4-change|dhcp6-change|connectivity-change) ;;
	*) exit 0 ;;
esac
[ -x /usr/local/sbin/kickpi-k1-eee-off.sh ] || exit 0
( /bin/sh /usr/local/sbin/kickpi-k1-eee-off.sh >>/var/log/kickpi-k1-eee-off.log 2>&1 & ) >/dev/null 2>&1
exit 0
EOF
chmod 0755 /etc/NetworkManager/dispatcher.d/90-kickpi-k1-eee-off

systemctl daemon-reload
systemctl enable --now kickpi-k1-eee-off.service >/dev/null 2>&1
/bin/sh /usr/local/sbin/kickpi-k1-eee-off.sh
sleep 1
eee_fail=0
for n in /sys/class/net/*; do
	[ -e "$n" ] || continue
	nic=${n##*/}
	case "$nic" in lo|docker*|veth*|br-*|virbr*|wg*) continue ;; esac
	st=$(ethtool --show-eee "$nic" 2>/dev/null | awk -F': ' '/^EEE status/{print $2}')
	[ -z "$st" ] && continue
	printf '  %-6s EEE=%s\n' "$nic" "$st"
	[ "$st" = "disabled" ] || eee_fail=1
done
[ "$eee_fail" = 0 ] && ok "所有支持 EEE 的网口均 disabled（判据达标）" \
                    || bad "仍有网口 EEE 未关（见上表）"

# ── 2) mask 本板无对应硬件/未配置的厂商单元（与本仓 build-k1-fnos.sh (3) 段同决策）──
say "2) mask 厂商残留单元（exim4/pwm-fancontrol/nut-*/smartmontools/networking）"
masked=""
for u in pwm-fancontrol nut-monitor nut-server smartmontools exim4 networking; do
	present=0
	for d in /etc/systemd/system /usr/lib/systemd/system /lib/systemd/system; do
		[ -e "$d/$u.service" ] && { present=1; break; }
	done
	[ "$present" = 1 ] || continue
	# 清掉可能存在的 wants 链（否则开机仍尝试启动）
	rm -f "/etc/systemd/system/multi-user.target.wants/$u.service" "/etc/systemd/system/sysinit.target.wants/$u.service" 2>/dev/null
	ln -sf /dev/null "/etc/systemd/system/$u.service"
	systemctl daemon-reload 2>/dev/null || true
	masked="$masked $u"
done
[ -n "$masked" ] && ok "已 mask:$masked" || echo "  (无需 mask 的单元)"
systemctl reset-failed 2>/dev/null || true

# ── 3) webdav.service 可执行位 ───────────────────────────────────────────
say "3) 修 webdav.service 可执行位告警"
if [ -f /etc/systemd/system/webdav.service ]; then
	chmod 644 /etc/systemd/system/webdav.service
	systemctl daemon-reload
	ok "已 chmod 644（systemd 启动告警消失）"
else
	echo "  (无 webdav.service)"
fi

# ── 4) TF 卡 boot 分区 FAT 脏位（仅当卡在位且未挂载）────────────────────
say "4) TF 卡 boot 分区 FAT 脏位（只认 K1 卡：LABEL=armbi_boot，且未挂载）"
if [ -b /dev/mmcblk1p1 ] && ! grep -q '/dev/mmcblk1p1' /proc/mounts \
	&& [ "$(blkid -s LABEL -o value /dev/mmcblk1p1 2>/dev/null)" = "armbi_boot" ]; then
	out=$(fsck.vfat -a /dev/mmcblk1p1 2>&1); echo "$out" | tail -3 | sed 's/^/  /'
	echo "$out" | grep -qi 'dirty\|removing' && ok "脏位已清（K1 启动不再报 not properly unmounted）" || echo "  (无脏位)"
else
	echo "  (跳过：卡不在位 / 已挂载 / 不是 K1 卡（LABEL≠armbi_boot）)"
fi

# ── 5) 复检 ─────────────────────────────────────────────────────────────
say "5) 复检"
echo "  --- systemctl --failed ---"
systemctl --failed --no-pager | sed 's/^/  /'
echo "  --- 本轮 err 级计数 ---"
printf '  %s 条\n' "$(journalctl -b -p err --no-pager 2>/dev/null | wc -l)"
echo
echo "  备份目录：$BK"
echo "  注意：mask 与 EEE 持久件均已落盘，重启后仍生效；无需立即重启。"

# ── 附：良性噪声白名单（**不要改**）────────────────────────────────────
#   · MDIO device at address 1 is missing        —— 第二网口占位节点，正常
#   · invalid boot record signature / failed to recognize exfat type /
#     Can't find valid F2FS(erofs) superblock    —— blkid 挨个试文件系统的探测噪声
#   · sdhci-dwcmshc ... Can't reduce the clock below 52MHz   —— 信息级
#   · sshd[..]: ipblocker: connect(/run/trim_ipblocker.sock) failed
#                                                —— 启动早期套接字未建，之后 active
#   · nmbd dump_workgroups()/current master browser          —— Samba 正常输出
#   · [SKWSDIO INFO] skw_* / client N driver is not ready!   —— SWT6621S 驱动启动打印
