# KICKPI K1 飞牛 fnOS —— OTA 升级验收单

目的：确认**在线升级换内核后**，树外模块（maxio + SWT6621S 三件）自动重编成功，
网口/WiFi/BT 不是"降级但能跑"，而是与升级前同级。

## 0. 为什么需要这张单

四个都是树外编译的模块，vermagic 绑内核版本：

| 模块 | 作用 | 没了会怎样 |
|---|---|---|
| `maxio` | Maxio MAE0621A PHY | 网口退回 Generic PHY：速率/双工/RGMII 参考时钟都可能不对，常见表现是只跑 100M 或链路时断时续 |
| `swt6621s_wifi` | 板载 SDIO WiFi | 没有 wlan 接口 |
| `skw_sdio_lite` | Seekwave SDIO 公共层 | WiFi 起不来（依赖它） |
| `skwbt` | 蓝牙 | 没有 hci 设备 |

镜像自带 `/usr/src/kickpi-k1-modules/`（maxio.c + wifi-src.tar.gz）与
`kickpi-k1-modules-ensure.service`：开机时若当前内核没有可用模块，就用设备上的
`/lib/modules/$(uname -r)/build` + gcc + make 现场重编（日志
`/var/log/kickpi-k1-modules-ensure.log`）。失败不阻塞开机。

**实机基线（6.18.18.c1145-trim，原生 aarch64 gcc，2026-10-27 验过）**：4/4 全部重编成功，
耗时约 75–100 秒；产物 vermagic 全部等于运行内核。

> **引导参数口径（2026-10-27 定案）**：`extraargs=cma=256M`，与官方 R5S 完全一致
> （官方 DTB 无 reserved CMA 区，cmdline 的 `cma=` 是唯一决定因素）。验收时必须核到 256M；
> 相册 AI 的重负载在 256M 下会失败（rknpu 单次 173/339MB 连续 DMA），属官方同口径的已知限制，
> 由硬件看门狗 44s 兜底 —— 不要为此把 CMA 放大后当"验收通过"。

## 1. 升级前：留基线（升级前后要能对比）

```sh
# 内核与模块
uname -r | tee /tmp/ota-before.txt
lsmod | grep -E '^(maxio|swt6621s_wifi|skw_sdio_lite|skwbt)' | tee -a /tmp/ota-before.txt

# 网口（两口都要）：速率/双工/链路 + 计数器
for i in $(ls /sys/class/net | grep -E '^(eth|enp)'); do
  echo "== $i" | tee -a /tmp/ota-before.txt
  ethtool "$i" 2>/dev/null | grep -E 'Speed|Duplex|Link detected' | tee -a /tmp/ota-before.txt
  ethtool -S "$i" 2>/dev/null | grep -E 'rx_packets|rx_errors|rx_crc_errors|tx_packets' | tee -a /tmp/ota-before.txt
done

# WiFi / BT
iw dev 2>/dev/null | grep Interface | tee -a /tmp/ota-before.txt
hciconfig 2>/dev/null | grep -E '^hci' | tee -a /tmp/ota-before.txt

# LED
ls /sys/class/leds | tee -a /tmp/ota-before.txt

# 丢包基线（跑 60 秒）
ping -c 60 -i 1 <上位机IP> | tail -3 | tee -a /tmp/ota-before.txt
```

把 `/tmp/ota-before.txt` 拷出来留存。

## 2. 升级后：必须逐项过

### P1 —— 网络（最要紧，必须有线先通）

```sh
# ① 自愈是否真跑过、结果几条
cat /var/log/kickpi-k1-modules-ensure.log | tail -5
#   期望：结果：4/4 可用（加载由 modules-load.d 决定）

# ② 四个模块的 vermagic 必须都等于当前内核
K=$(uname -r)
for m in maxio swt6621s_wifi skw_sdio_lite skwbt; do
  printf '%-16s ' $m; modinfo -F vermagic /usr/lib/modules/$K/updates/kickpi-k1/$m.ko 2>/dev/null || echo 缺失
done
#   判据：四行全部 == $K（出现"缺失"或不匹配 = P1 失败）

# ③ 模块真的加载了
lsmod | grep -E '^(maxio|swt6621s_wifi|skw_sdio_lite|skwbt)'

# ④ 链路速率必须与升级前一致（这是"降级但能跑"的核心判据）
for i in $(ls /sys/class/net | grep -E '^(eth|enp)'); do
  echo "== $i"; ethtool "$i" | grep -E 'Speed|Duplex|Link detected'
done
#   判据：有线的口 Speed 必须是 1000Mb/s（或 2500Mb/s），且 Link detected: yes
#   若退成 100Mb/s / Unknown / 没链路 → 说明 maxio 没生效，走 generic PHY，P1 失败

# ⑤ 收发计数必须都在涨、错误不涨（放 60 秒观察）
S1=$(ethtool -S eth0 | awk '/rx_packets/{print $2}'); sleep 60
S2=$(ethtool -S eth0 | awk '/rx_packets/{print $2}')
echo "rx_packets: $S1 -> $S2"
ethtool -S eth0 | grep -E 'rx_errors|rx_crc_errors'
#   判据：rx_packets 明显增长；rx_errors / rx_crc_errors 不增长
#   （只有"能发不能收"或"收包停住"才算彻底失败 —— 那是 EEE/延迟问题，见下）
```

### P2 —— WiFi / BT

```sh
iw dev | grep Interface          # 期望：wlan0 存在
ip link show wlan0 | head -2
hciconfig | grep -E '^hci'       # 期望：hci0（BT 正常）
dmesg | grep -iE 'seekwave|swt6621|skw' | tail -10   # 无 -2/-5 类错误码
```

### P3 —— 灯与温度

```sh
ls /sys/class/leds                    # blue:net / amber:sata … 命名不变
cat /sys/class/leds/*/trigger         # 与升级前一致
sensors 2>/dev/null | head -8 || cat /sys/class/thermal/thermal_zone*/temp
```

## 3. 判据汇总（过了才算"真通"）

| 级别 | 项目 | 通过标准 |
|---|---|---|
| P1 | 自愈日志 | `结果：4/4 可用` |
| P1 | vermagic | 四个模块全部 == `uname -r` |
| P1 | 有线速率 | 与升级前一致（1000/2500，不是 100/Unknown） |
| P1 | 收发 | rx_packets 持续增长，rx_errors/rx_crc 不涨，ping 60 包丢 0 |
| P2 | WiFi | `iw dev` 有 wlan0，能扫描到 AP |
| P2 | BT | `hciconfig` 有 hci0 |
| P3 | LED/温度 | 命名与 trigger 不变，温度正常区间 |

## 4. 失败处置

| 现象 | 原因 | 处置 |
|---|---|---|
| 日志写"maxio 重编失败" | 新内核改了 PHY API（典型：`.led_dt_managed` vs `led_hw_control_get`） | 更新 `modules/src/maxio.c` 到新 API，重刷；期间有线可能退 generic PHY |
| 日志写"SWT6621S 重编失败" | 新内核对 cfg80211/sdio API 有变动 | 更新 `patches/wifi-6.18-port.patch` |
| 4/4 都成功但速率仍 100M | 不是模块问题：查 DTS 的 `phy-mode`/`tx_delay`/`rx_delay`，以及 EEE（对端协商 1G EEE 会打死 RX） | 见 `docs` 里 EEE 定案：PHY 加 `eee-broken-1000t` |
| 日志文件都不存在 | 自愈单元没起来 | `systemctl status kickpi-k1-modules-ensure`；确认 `/usr/src/kickpi-k1-modules/` 在 |

## 5. 已知边界

- 自愈依赖**内核头文件**：`/lib/modules/$(uname -r)/build` 必须存在（fnOS 有自带 headers，
  实机确认）。若某次 OTA 只换内核不给 headers，自愈会放弃并记日志 → 需手动补 headers 后重启。
- `depmod -a` 在 fsOS 上会打印 `fstatat(5, alternatives)` 报错，非致命：加载走绝对路径 insmod 与
  modules-load.d，不依赖 modules.dep。
- 重编耗时 75–100 秒（maxio 4s + WiFi 67s），发生在开机早期，不影响最终可用。
