# AUD-8：认证用户锁错误分类修复

2026-11-15。本轮以独立评审检查点 `9b0f5f045fea9996f695e03d23dba9cd2ec47bc5` 为保存候选，Git HEAD仍为 `d01f49dbadd87e0b9b1ceb185a2fce7b872cd28b`。未暂存、提交、改动Git引用或监督器。需求版本7不变，Rust/PostgreSQL/Swift、邮箱、HTTPS及隐私要求均保留。

## 修复与实际复现

评审正确。先添加真实HTTP回归，在隔离PostgreSQL事务内持有用户行锁，等待生产代码的4000ms锁超时：登录、刷新、退出、退出全部设备错误返回401；验证、重置及邮箱独立注册错误返回400。修复前聚焦命令退出1，4项测试中有7个子场景失败，日志保留于 `docs/validation/auth-lock-timeout-before.txt`。

业务修复仅在 `backend/src/auth.rs`：新增统一的用户锁错误转换，仅将 `lock_user` 明确返回的缺失用户结果（401/unauthorized）映射为相应认证错误，其他错误原样传播。邮件凭据、登录、刷新及退出四处调用共同使用该转换；锁超时返回503/storage_unavailable。没有修改锁顺序、超时配置、连接池、分页、Swift或同意屏障。

`backend/tests/test_email_auth.py` 新增4项测试，覆盖上述7个超时分支，断言等待发生在真实PostgreSQL锁上、超时后会话/密码/未消费邮件凭据仍有效，锁释放后同一请求可成功重试。另在验证及刷新等待期间实际删除用户，确认真正缺失用户仍返回400/invalid_credential或401/authentication_failed。独立注册超时及重试均保留旧身份、历史与同意状态；邮件仅发到本任务回环捕获器。

## 本轮命令与结果

聚焦命令（修复前后选择器一致）：

```sh
python3 -m unittest \
  backend.tests.test_email_auth.EmailAuthTests.test_session_user_lock_timeouts_preserve_credentials_for_retry \
  backend.tests.test_email_auth.EmailAuthTests.test_mail_proof_user_lock_timeouts_do_not_consume_or_activate_proof \
  backend.tests.test_email_auth.EmailAuthTests.test_independent_registration_user_lock_timeout_preserves_both_identities \
  backend.tests.test_email_auth.EmailAuthTests.test_user_deleted_while_auth_waits_keeps_credential_error -v
```

- 修复后聚焦检查退出0，4项通过，56.393秒；日志 `docs/validation/auth-lock-timeout-focused.txt`。
- 一次相关回归 `python3 -m unittest backend.tests.test_email_auth -v` 退出0，29项通过，146.293秒；日志 `docs/validation/auth-lock-timeout-regression.txt`。夹具实际构建Rust并请求真实PostgreSQL/HTTP/隔离SMTP，使用临时schema和服务端口并清理，没有跳过测试。
- `cargo fmt --manifest-path backend/Cargo.toml --all -- --check` 初次退出1，仅要求将新增函数签名合为一行，日志 `docs/validation/auth-lock-timeout-format.txt`；按格式修正后退出0，日志 `docs/validation/auth-lock-timeout-format-final.txt`。该格式修正发生在上述完整邮箱回归之前。
- `python3 -m py_compile backend/tests/test_email_auth.py`、`git diff --check` 均退出0。
- 比较原32项源码指纹，只有 `backend/src/auth.rs`、`backend/tests/test_email_auth.py` 变化，其余30项不变。新清单 `docs/validation/auth-lock-timeout-sources.sha256` 的 `sha256sum -c` 退出0，32/32匹配，输出保存在 `docs/validation/auth-lock-timeout-source-check.txt`。旧清单与历史日志未改写。

摘要：

| 文件（docs/validation内） | SHA-256 |
| --- | --- |
| auth-lock-timeout-sources.sha256 | 1dad200a35c5ef75455b8e8bbc5d122ef71de27d63cd9d4467663d1080924245 |
| auth-lock-timeout-before.txt | 55ba5809d425147f344b60ff6be4ce47ab76a8620c8a098cadb48c3e41fb5cf6 |
| auth-lock-timeout-focused.txt | d8e385b1e605355ad8ba1b9c5035c41fb594d00dead239bdf72081bdb6227e46 |
| auth-lock-timeout-regression.txt | 6a091a199e338be9f9319223576a27218fbeb68c5d2fe9bc85a24d7ff4acd6d5 |

## 交审范围与限制

按依赖顺序提交同一候选的 `backend_rust_postgres`、`backend_identity`、`backend_social`、`backend_circles`、`backend_email_auth`、`backend_data_access`。四个前置模块沿用本次独立评审的重新确认；当前29项邮箱回归验证改动后的认证与隐私路径。连接池、分页和规模实验实现未变，保留 `docs/verification-13-data-access.md` 及第22轮108项Python/18项Rust成功证据，不把历史结果表述为修复后完整固定检查结果。三个固定交付命令留给Watcher对新候选实际执行，worker未重复完整发现命令。

AUD-8实现修复已完成，是否关闭由独立reviewer决定。AUD-9沿用已知Apple环境限制：本机缺少Swift、Xcode及iOS模拟器，不重试未变化的不可用环境，不冒称编译、XCTest、系统信任、签名或真机HealthKit通过。该限制不阻断此次后端修复。其余体验、Apple构建入口和最终集成交付模块仍在台账，本次不扩展或宣称整个需求完成。
