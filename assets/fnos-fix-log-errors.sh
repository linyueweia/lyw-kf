#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════
# 飞牛(fnOS / KICKPI K1) —— 存量系统日志错误修复（在线跑，幂等）
#
# 用途：把【已经在跑的】飞牛系统按本仓（lyw-kf）已定的决策修一遍，
#       不必重刷镜像。全部改动可回滚（备份在 /root/fnos-fix-backup-<时间戳>）。
#
# 依据（2026-10-13/14 实机日志取证，/root/fnos-logs-* 与桌面导出包）：
#   真故障：
#     1) 网口 EEE —— 2026-10-17 改判：不再关闭（当初的"EEE 开着 = 掉线"依据已被主路由
#        日志复核推翻：EEE 本就关闭时掉线仍发生，且每次都对应对端重启）。本脚本改为
#        清除历史遗留的三层 EEE 关闭件，按官方默认保持开启。
#     2) exim4.service failed —— 未配置的 MTA，日志目录都打不开
#        （Cannot open main log file "/var/log/exim4/mainlog": Permission denied）。
#        本仓决策 = mask（见 build-k1-fnos.sh (3) 段：exim4 = 未配置）。
#     3) pwm-fancontrol.service failed —— `No fan configuration found in /boot/board.json`；
#        本板风扇由内核 gpio-fan 管，本仓决策 = mask（同上 (3) 段）。
#     4) webdav.service 每次启动告警 "marked executable" → chmod 644。
#     5) 每次启动还报 networking.service（ifupdown 残留）→ 本仓决策 = mask。
#     6) 相册 AI 整机挂死（2026-10-14 两次实机取证）—— rknpu 要 173/339MB 连续 DMA，
#        而 fnEnv.txt 的 cma=256M < 339MB 请求 → 必失败 → 闭源驱动挂住内核，只能断电。
#        → fnEnv.txt extraargs cma=256M → 1G（重启生效）。
#     7) 硬件看门狗无人管（官方零管理：/usr/trim 全家无一引用 /dev/watchdog）
#        → 装 Debian 标准 watchdog 包挂 /dev/watchdog0（Synopsys DW，44s 超时无 magic close），
#          内核再挂死时 44s 内硬复位自愈，不再依赖人工断电。
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
for f in /etc/systemd/system/net-nosleep.service /etc/systemd/system/webdav.service /boot/board.json /boot/fnEnv.txt; do
	[ -e "$f" ] && cp -a "$f" "$BK/" 2>/dev/null
done
systemctl --failed --no-pager > "$BK/units-failed-before.txt" 2>&1 || true
for n in end0 end1 eth0 eth1; do
	[ -e "/sys/class/net/$n" ] && ethtool --show-eee "$n" 2>/dev/null > "$BK/eee-$n-before.txt"
done
ok "已备份（含修复前 failed 单元与 EEE 状态）"

# ── 1) EEE：不再关闭（2026-10-17 改判）+ 清除历史关闭件 ──────────────────
say "1) EEE 保持官方默认；清除历史遗留的三层关闭件"
for f in /usr/local/sbin/kickpi-k1-eee-off.sh \
         /etc/systemd/system/kickpi-k1-eee-off.service \
         /etc/NetworkManager/dispatcher.d/90-kickpi-k1-eee-off; do
	if [ -e "$f" ]; then rm -f "$f"; echo "  · 已删除历史 EEE 关闭件: $f"; fi
done
systemctl disable kickpi-k1-eee-off.service >/dev/null 2>&1 || true
systemctl daemon-reload >/dev/null 2>&1 || true
for n in /sys/class/net/*; do
	[ -e "$n" ] || continue
	nic=${n##*/}
	case "$nic" in lo|docker*|veth*|br-*|virbr*|wg*) continue ;; esac
	st=$(ethtool --show-eee "$nic" 2>/dev/null | awk -F": " "/^EEE status/{print \$2}")
	[ -z "$st" ] && continue
	printf "  %-6s EEE=%s（不干预）\n" "$nic" "$st"
done
ok "EEE 未做任何关闭（历史件已清；按官方默认保持开启）"
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

# ── 5) NPU CMA 扩容：fnEnv.txt extraargs cma=256M → 1G ────────────────────
say "5) NPU CMA 扩容（相册 AI 整机挂死根因：rknpu 请求 173/339MB > cma=256M 总量）"
# 病理（2026-10-14 两次实机取证，kern.log 现场）：
#   trim.img2vec → drm_ioctl → rknpu_gem_object_create → dma_direct_alloc 一次要
#   181448704 或 355860480 字节连续 DMA；CMA 池总量 256M < 339M 请求 → 必失败（-16）；
#   闭源 rknpu 0.9.8 失败路径把内核挂死（日志戛然而止、无 panic 输出），只能断电。
#   修法：CMA 1G（4GB 内存下空闲时可被普通 movable 页借用，不浪费）。
if [ -f /boot/fnEnv.txt ]; then
	if grep -q '^extraargs=.*cma=256M' /boot/fnEnv.txt; then
		sed -i 's/\(extraargs=.*\)cma=256M/\1cma=1G/' /boot/fnEnv.txt
		ok "fnEnv.txt: cma=256M → cma=1G（重启后生效）"
	elif grep -q '^extraargs=.*cma=' /boot/fnEnv.txt; then
		ok "fnEnv.txt 已含非 256M 的 cma 值，不动：$(grep '^extraargs=' /boot/fnEnv.txt)"
	else
		grep -v '^extraargs=' /boot/fnEnv.txt > /tmp/_fnenv.keep
		{ cat /tmp/_fnenv.keep; echo "extraargs=cma=1G loglevel=7 ignore_loglevel"; } > /boot/fnEnv.txt
		ok "fnEnv.txt 新增 extraargs=cma=1G loglevel=7 ignore_loglevel（重启后生效）"
	fi
else
	bad "/boot/fnEnv.txt 不存在（本脚本只针对 fnOS）"
fi

# ── 6) 硬件看门狗守护：挂死 44 秒硬复位，不再人工断电 ──────────────────────
say "6) 硬件看门狗（官方零管理：/usr/trim 无一引用 /dev/watchdog，挂死只能断电）"
if ! command -v watchdog >/dev/null 2>&1; then
	DEBIAN_FRONTEND=noninteractive apt-get install -y -qq watchdog >/dev/null 2>&1 \
		&& ok "已装 Debian 标准 watchdog 包" \
		|| bad "watchdog 包安装失败（无网络/源？）——看门狗未启用，挂死仍需断电"
fi
if command -v watchdog >/dev/null 2>&1; then
	grep -qE '^watchdog-device\s*=\s*/dev/watchdog0' /etc/watchdog.conf 2>/dev/null \
		|| echo 'watchdog-device = /dev/watchdog0' >> /etc/watchdog.conf
	systemctl enable watchdog.service >/dev/null 2>&1
	systemctl restart watchdog.service >/dev/null 2>&1
	sleep 2
	if systemctl is-active --quiet watchdog.service; then
		ok "watchdog.service active（$(wdctl 2>/dev/null | awk '/^Device/{print $3} /Timeout/{print "超时"$3"s"}' | tr '\n' ' ' | sed 's/  */ /g')）"
	else
		bad "watchdog.service 未能启动：journalctl -u watchdog.service -n 20 查原因"
	fi
fi

# ── 7) 复检 ─────────────────────────────────────────────────────────────
say "7) 复检"
echo "  --- systemctl --failed ---"
systemctl --failed --no-pager | sed 's/^/  /'
echo "  --- 本轮 err 级计数 ---"
printf '  %s 条\n' "$(journalctl -b -p err --no-pager 2>/dev/null | wc -l)"
echo
echo "  备份目录：$BK"
echo "  注意：mask 单元与 EEE 清理已落盘，重启后仍生效；无需立即重启。"

# ── 附：良性噪声白名单（**不要改**）────────────────────────────────────
#   · MDIO device at address 1 is missing        —— 第二网口占位节点，正常
#   · invalid boot record signature / failed to recognize exfat type /
#     Can't find valid F2FS(erofs) superblock    —— blkid 挨个试文件系统的探测噪声
#   · sdhci-dwcmshc ... Can't reduce the clock below 52MHz   —— 信息级
#   · sshd[..]: ipblocker: connect(/run/trim_ipblocker.sock) failed
#                                                —— 启动早期套接字未建，之后 active
#   · nmbd dump_workgroups()/current master browser          —— Samba 正常输出
#   · [SKWSDIO INFO] skw_* / client N driver is not ready!   —— SWT6621S 驱动启动打印
