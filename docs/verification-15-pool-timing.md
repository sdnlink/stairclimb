# AUD-10：连接池测试建连时序修复

2026-11-15。基于独立评审候选 `64264e3fd1f0fefd52c36500df34242587e8534e`，HEAD仍为 `d01f49dbadd87e0b9b1ceb185a2fce7b872cd28b` 加保存的工作区差异。未暂存、提交、改变Git引用或修改监督器。需求版本7、Rust/PostgreSQL/Swift、邮箱、HTTPS及隐私要求不变。

Watcher第23轮的固定Cargo检查已实际失败：断连替换测试把80ms耗尽预算同时当作真实新连接必须完成的时限，获取替代连接返回database_busy。该失败及评审判断有效；没有生产池槽位泄漏证据，本次不修改生产连接池。

唯一源码增量是 `backend/src/storage.rs` 中 `cfg(test)` 的 `postgres_pool_bounds_timeout_reuse_rollback_and_broken_connection`：预热、可用租约获取及断连替换使用本测试局部函数，仅对database_busy在5秒窗口内有限重试。每次获取仍使用原80ms期限；总等待上界为重试窗口加最后一次获取期限（不计系统线程调度延迟）。其他错误立即失败，持续不恢复也会失败，不跳过测试或吞掉数据库故障。

保留原连接上限2、持有两个租约时直接获取必须database_busy、耗尽等待至少60ms且小于1秒、失败事务回滚、复用同一PID、实际终止连接及替代PID不同的全部断言。相对上轮32项清单仅storage.rs变化，31项不变；还实际比较保存检查点与当前storage.rs首个cfg(test)之前的字节，生产部分完全一致。AUD-8认证代码、Python回归、pool.rs、分页及Swift均保持原样。

## 本轮实际检查

| 命令 | 退出与结果 | 日志（docs/validation内） |
| --- | --- | --- |
| `cargo test --locked --manifest-path backend/Cargo.toml storage::pool_tests::postgres_pool_bounds_timeout_reuse_rollback_and_broken_connection -- --exact` | 0，1项通过、0忽略 | pool-timing-focused.txt |
| `cargo test --locked --manifest-path backend/Cargo.toml --all-targets` | 0，18项通过、0忽略，默认并行，无线程数覆盖 | pool-timing-regression.txt |
| `cargo fmt --manifest-path backend/Cargo.toml --all -- --check` | 最终0 | pool-timing-format-final.txt |
| `sha256sum -c docs/validation/pool-timing-sources.sha256` | 0，32/32匹配 | pool-timing-source-check.txt |
| `git diff --check` | 0 | worker工具记录 |

初次格式检查退出1，只要求将match分支条件合为一行，保存在pool-timing-format.txt；已修正，并在最终格式通过的源码上运行上述完整Cargo回归。没有重复完整回归。没有为本次仅测试代码的修复重跑已通过的Python完整发现命令；上一候选Watcher的112项Python检查及AUD-8的29项邮箱回归保留原证据，不冒称新候选已获Watcher接受。

SHA-256：

- pool-timing-sources.sha256：`2a8092f2e9ea6e3f00114def82e31ae119c0da484c50418733ff9a9ade243dd3`
- pool-timing-focused.txt：`333a14d775356bdb6851594d9d84a6a06df55ddcb875d637e6e89f48ba991886`
- pool-timing-regression.txt：`da65563602c41dd2dfa7808fb9ad8bbc5049b413746932f105ed25c37bcae8fb`

按依赖顺序联合交审backend_rust_postgres、backend_identity、backend_social、backend_circles、backend_email_auth、backend_data_access，沿用独立评审已确认的未变行为；AUD-10是否关闭由reviewer决定。三个固定检查继续由Watcher验证当前候选。既有模块定义、历史日志及指纹清单均未改写。

AUD-9/AUD-11继续属于已知Apple平台环境限制，不阻断此次后端测试修复；未重试未变化的不可用工具，不声称Swift编译、XCTest、系统信任、签名或真机HealthKit通过。ios_freshness、apple_build_validation和三个最终交付模块继续在台账中，本次不扩展范围或宣称整个需求完成。
