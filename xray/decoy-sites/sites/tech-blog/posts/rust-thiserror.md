---
title: 用 thiserror 整理一个小项目的错误类型
date: "__DATE2__"
tag: Rust
order: 2
summary: 早期到处都是 Box<dyn Error>，到了要按错误类型返回不同状态码时就很难受。最后改成每个模块一个错误枚举。
---

项目早期图省事，到处都是 `Box<dyn Error>`。到了要按错误类型返回不同 HTTP 状态码时，只能对着字符串做匹配，非常难受。

## 每个模块一个错误枚举

最后的做法是每个模块定义自己的错误类型，在边界处统一转换：

```rust
#[derive(Debug, thiserror::Error)]
pub enum StoreError {
    #[error("record {0} not found")]
    NotFound(u64),
    #[error("database error")]
    Db(#[from] sqlx::Error),
}
```

`#[from]` 让 `?` 可以直接把底层错误转换过来。注意 `Display` 只描述这一层发生了什么，底层原因留给 `source()`，不要把下层的信息再拼进自己的消息里，否则日志里会重复好几遍。

## 在 HTTP 边界转换

```rust
impl From<StoreError> for ApiError {
    fn from(error: StoreError) -> Self {
        match error {
            StoreError::NotFound(_) => ApiError::NotFound,
            StoreError::Db(_) => ApiError::Internal,
        }
    }
}
```

打日志时用 `{:#}` 或者 `anyhow` 的错误链，一次就能看到完整的原因链条。
