---
title: 家里的 NAS 换上 ZFS 半年后
date: "__DATE3__"
tag: 自建服务
order: 3
summary: 四块 8T 盘组 RAIDZ1 跑了半年，说说快照、scrub 和内存占用这几件事的实际感受。
---

四块 8T 盘组 RAIDZ1，跑了半年，记几点实际感受。

## 快照是最值的功能

每小时一个快照、保留两天，每天一个、保留一个月。误删文件基本都能自己从 `.zfs/snapshot` 里找回来，再也不用翻备份盘。

```bash
zfs list -t snapshot -o name,used,creation tank/home | tail -5
```

## scrub 要挑时间

每月一次的 `zpool scrub` 跑完大约九个小时，期间读写会明显变慢，所以放在周日凌晨。

## 内存

ARC 默认会吃掉一半内存，跟其他服务抢资源时可以限制一下：

```bash
echo 8589934592 > /sys/module/zfs/parameters/zfs_arc_max
```

## 下次扩容

RAIDZ1 在大容量盘上重建时间很长，期间再坏一块就麻烦了。下次扩容大概会换成两组镜像，空间少一些，但重建快得多。
