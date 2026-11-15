# backend_email_auth：AUD-5 有界修复

依据需求版本7（`0f0b02550ca7868604bdb2b3c4a4bd9d0d0887041c6572f956de80a4d3c87f37`）继续邮箱认证；原需求和后发Rust/PostgreSQL、邮箱/HTTPS及优化要求均保留。本轮仅修未验证旧身份绑定的邮箱占用，不推进其他模块、不改不可变模块定义。起始HEAD仍为`3cf9e4c2d2a71d6af49ff57b3d9d2fca493183e2`，上轮完整worker checkpoint为`b390f1e5b770ce8798dacbfdf1f40c6eb919dfb1`。

AUD-5判断正确。先新增真实HTTP回归并在修复前运行：普通注册收到占位凭据、旧身份重置缺Bearer为401，新安全入口当时404，测试实际失败，见[修复前日志](validation/backend-email-auth-aud5-before.txt)，退出1。没有把静态推断直接当作已执行复现。

新增`POST /v1/auth/register-independent`，只接受`token,password,nickname`。邮箱主人先读取`forgot-password`实际邮件的有效reset凭据，再明确选择独立注册；服务在原写事务屏障后重验期限及`legacy_binding=true,verified=false`。只取消旧身份未验证邮箱关联，在同一事务建立全新ID和邮箱已验证账号；新账号默认不共享、不参加圈子、不自动登录。原用户ID、凭证摘要、昵称、全部历史、共享版本及圈子均不改，也不复制给新账号。旧绑定和找回凭据级联失效。原`verify`/`reset-password`取得旧身份所需的双重证明不放宽；已验证账号、普通注册、非法/过期/重放凭据不能走新入口。无需新增迁移或清库；现有002约束和事务足以原子完成。

逐文件对照上述worker checkpoint，业务差异只在`backend/src/auth.rs`、`backend/tests/test_email_auth.py`、`docs/EMAIL_AUTH.md`。其余已验证源码、配置、迁移及历史证据保持。五项新增真实HTTP/数据库/SMTP回归覆盖独立注册、两用户身份隔离、旧用户完整快照、过期与重启、旧绑定/重置重放、已验证及非legacy保护、非法输入和并发一次成功。

当前修复源码清单见[backend-email-auth-aud5-sources.sha256](validation/backend-email-auth-aud5-sources.sha256)：25项匹配，清单SHA-256为`693868c427a8ef6c4b88bbb3cb3210a9286bfec8f70eba44c33aeb31ad343f5b`。未变本机模块的38项当前清单仍匹配，不重跑相同结构回归。

`python3 -m unittest backend.tests.test_email_auth -v`：25项通过，102.596秒，退出0，见[聚焦日志](validation/backend-email-auth-aud5-focused.txt)。先聚焦，再只运行一次完整相关回归；固定命令未删改，外部Watcher仍自行执行候选检查。

| 最终实际命令 | 结果 |
| --- | --- |
| `python3 -m unittest discover -s backend/tests -p 'test_*.py' -v` | 92项通过，170.343秒，退出0；[完整HTTP回归](validation/backend-email-auth-aud5-regression-1.txt) |
| `cargo test --locked --manifest-path backend/Cargo.toml --all-targets` | 14项通过，0忽略，退出0；[Rust回归](validation/backend-email-auth-aud5-regression-2.txt) |
| `cargo fmt --manifest-path backend/Cargo.toml --all -- --check` | 退出0；[格式检查](validation/backend-email-auth-aud5-regression-3.txt) |
| `git diff --check` | 退出0 |

这些是worker实际运行结果，不冒称本轮外部Watcher已接受。此前87项与其他历史日志保持不变，新增5项使当前数量为92。独立reviewer另行只读复核本修复，不以旧20项认证测试通过替代AUD-5验证。

AUD-6保持已知环境事实：Linux缺少Swift、Xcode及iOS模拟器，Swift编译、XCTest、系统ATS、签名、真机HealthKit及视觉/断网/午夜/圈子切换仍需Mac/iPhone。本轮没有重试不可用工具、创建替代平台或伪造通过。原需求明确允许Linux继续后端及源码交付，所以该事实不是本次后端修复的代码缺口；其审计分类由独立reviewer处理，worker不自行关闭ID。README和既有Mac命令保持。

未扩展`https_transport`、`ios_email_auth`、`ios_network`、`ios_circles`、三项优化或最终集成交付；持续实例仍留到最终交付。按既有依赖要求，本次联合列出此前已核验的五个前置与修复后的`backend_email_auth`，由独立reviewer和Watcher决定接受状态，不直接修改监督器、Git引用、历史或运行状态。
