# tools/offline-read —— Windows 下离线读 Linux 盘（免装驱动）

2026-10-12 复盘时固化下来的工具：当时要在 Windows 上读一块 ext4 移动硬盘和 TF 卡的
btrfs rootfs 做取证，Windows 没有对应文件系统驱动，也不想装第三方驱动，于是用
纯 Python 直读原始磁盘。**都必须以管理员权限运行**（要开 `\\.\PhysicalDriveN`）。

## 依赖

```bash
pip install dissect.ext4 dissect.btrfs
```

## 用法

```bash
# 1) 先确认盘号与分区（PowerShell）
Get-Disk | Format-Table Number,FriendlyName,BusType,Size
Get-Partition | Format-Table DiskNumber,PartitionNumber,Type,Size,DriveLetter

# 2) ext4 分区：列目录（第三个参数是 GPT 分区号，最后一档数字是深度）
python tools/offline-read/ext4extract.py \\.\PhysicalDrive1 list 1 / 3
#    提取到 D:\out（后面的参数是要提取的路径，可多个）
python tools/offline-read/ext4extract.py \\.\PhysicalDrive1 extract 1 D:\\out /etc /var/log

# 3) btrfs 分区（飞牛 rootfs 是 btrfs）
python tools/offline-read/btrfs_dump.py list     \\.\PhysicalDrive2 2 / 2
python tools/offline-read/btrfs_dump.py extract  \\.\PhysicalDrive2 2 D:\\dump /var/log /etc

# 4) 只校验镜像里的 FIT 哈希（见 ../fit-resign.py）
python tools/fit-resign.py C:/path/to/image.img
```

## 文件说明

| 文件 | 作用 |
|------|------|
| `diskio.py` | `RawDisk`：Windows 原始磁盘读取。**必须 512 字节对齐**偏移与长度，否则 `ReadFile` 返回 `ERROR_INVALID_PARAMETER`；内置对齐窗口 + 缓存 + `IOCTL_DISK_GET_LENGTH_INFO` 取容量 |
| `ext4extract.py` | 纯 Python ext4：解析 GPT、列目录、按路径提取；含 `gpt_partitions()`（供 btrfs 工具复用） |
| `btrfs_dump.py` | 纯 Python btrfs：列目录、按路径提取（`dissect.btrfs` 只读，足够取证） |

## 坑（都是实测踩过的）

- **没有管理员权限** → `CreateFile(\\.\PhysicalDriveN)` 报 `ACCESS_DENIED(5)`。
- **读偏移/长度没对齐到 512** → `ERROR_INVALID_PARAMETER(87)`；别自己直接 `open()` 原始盘。
- **按路径递归解析 inode 是 O(n²)**：8 万文件跑不完。列目录要用 `opendir()`/`iterdir()`
  拿 inode 号直接取节点（`btrfs_dump.py` 与 `ext4extract.py` 已按此实现）。
- **`ext4` 库的 `Inode.size` 不可信**（实测恒为 160），用 `i_size`。
- Windows 资源管理器里盘"未知/无盘符"≠ 盘坏：先用 `Get-Partition` 看类型与大小，
  再按上面方式直读。
- 串口同理：设备被别的程序占用会报 `错误 5`，正在重新枚举时报 `错误 2`，
  先释放占用（本机 MobaXterm 就占过 COM3）。
