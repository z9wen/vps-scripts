---
title: PostgreSQL 部分索引：给“未处理”的那一小撮行建索引
date: "__DATE1__"
tag: 数据库
order: 1
summary: 订单表两千多万行，后台天天查的只是 pending 的那几千行。普通索引又大又浪费，部分索引正好合适。
---

订单表有两千多万行，但后台天天查的只是 `status = 'pending'` 的那几千行。给整列建普通索引，体积大不说，大部分条目永远用不上。

## 部分索引

这种场景正适合部分索引，索引里只放满足条件的行：

```sql
CREATE INDEX CONCURRENTLY orders_pending_idx
    ON orders (created_at)
    WHERE status = 'pending';
```

建好以后，索引从 600 多 MB 降到了不到 1 MB，后台列表页的查询从几百毫秒降到个位数。

## 规划器什么时候会用它

查询条件必须能推出索引的 `WHERE` 子句，规划器才会选它：

```sql
-- 会用到 orders_pending_idx
SELECT id FROM orders
WHERE status = 'pending'
ORDER BY created_at
LIMIT 50;
```

用参数化查询写成 `status = $1` 时要小心：prepared statement 跑过几次之后可能切换到通用计划，这时规划器不知道参数值，就用不上部分索引。状态值固定的话，直接写成常量更稳妥。

## 顺手做的两件事

- 用 `pg_stat_user_indexes` 看了一圈，删掉了三个半年没被扫描过的索引。
- 给 `status` 加了 `CHECK` 约束，避免哪天有人写进来一个拼错的状态值。
