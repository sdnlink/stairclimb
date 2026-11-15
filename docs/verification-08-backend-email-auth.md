# backend_email_auth：实现与交审

起始HEAD为`3cf9e4c2d2a71d6af49ff57b3d9d2fca493183e2`。本轮按最新授权优先实现邮箱认证后端，没有重写已验证Swift界面、换算/日期/圈子规则，也没有修改Auto Moniter源码、运行状态、历史记录或Git引用。旧不可变模块定义保持原样，新增优化只追加提案。

## 实现及覆盖关系

`backend/src/auth.rs`与增量迁移`002_email_auth.sql`实现规范化唯一邮箱、昵称注册、随机盐Argon2id、邮箱归属验证、重发、登录、可撤销access/refresh会话及轮换、单次/全部设备退出、忘记密码/一次性重置、原匿名凭证加邮箱归属证明的绑定。新账号和验证不自动同意健康共享或圈子。公开模型不含邮箱/密码/验证码/会话；邮箱仅本人账号接口返回。删除账号级联清理认证资料及会话，原有隐私版本屏障继续有效。

正式匿名注册关闭，旧凭证仍有必要的本人隐私管理及绑定路径；测试专用构建保留历史匿名场景。测试还运行正式二进制完成注册→验证→登录，并确认无法通过测试开关启用旧入口。业务写入取得原事务屏障后检查会话和当前时间，退出/重置/刷新/删除与业务写遵循一致锁序。会话和限流持久保存，限流独立提交，不随错误或邮件失败回滚。

`backend/src/mail.rs`使用lettre，生产仅强制TLS/STARTTLS、TLS1.2以上及受信任根/域名/有效期校验；显式本地捕获只允许字面回环IP，无SMTP身份密码。未配置或发送失败返回503，回滚此次账号/邮件凭据变更，不伪造投递。已检测现有25端口服务，未触碰；标准库隔离捕获器`scripts/smtp_capture.py`仅回环随机端口，文件在忽略目录且权限受限，测试后清理，没有外部邮件发送。

正式HTTP现在仅允许字面回环监听，拒绝0.0.0.0及局域网IP；HTTPS代理、本地可信CA和严格Swift地址/ATS仍由后续`https_transport`交付，本轮不声称已完成端到端HTTPS。API字段、邮箱/密码规范、邮件只表示上游接受、统一枚举响应、限流及回环代理共享来源额度等边界见[EMAIL_AUTH.md](EMAIL_AUTH.md)。README、API和无密钥SMTP示例已同步。

## 实际检查

先完成聚焦检查，后只运行一次相关完整回归，无失败后重复全量发现。初次开发编译发现lettre方法名为`set_min_tls_version`，已改正，后续`cargo check --locked --manifest-path backend/Cargo.toml --all-targets --features test-support`退出0；未将该开发编译错误当作功能测试成功。

| 命令 | 实际结果与日志 |
| --- | --- |
| `python3 -m unittest backend.tests.test_email_auth -v` | 当时18项通过，86.100秒，退出0；[聚焦日志](validation/backend-email-auth-focused.txt) |
| `python3 -m unittest backend.tests.test_email_auth.EmailAuthTests.test_production_binary_disables_legacy_and_external_http_listener backend.tests.test_email_auth.EmailAuthTests.test_binding_cannot_merge_existing_email_or_claim_another_identity -v` | 补充2项通过，10.087秒，退出0；[正式进程与绑定日志](validation/backend-email-auth-production.txt) |
| `python3 -m unittest discover -s backend/tests -p 'test_*.py' -v` | 最终87项（原67项保留+20项认证）通过，148.234秒，退出0；[完整HTTP回归](validation/backend-email-auth-regression-1.txt) |
| `cargo test --locked --manifest-path backend/Cargo.toml --all-targets` | 14项通过、0忽略，退出0；[Rust回归](validation/backend-email-auth-regression-2.txt) |
| `cargo fmt --manifest-path backend/Cargo.toml --all -- --check` | 退出0；[格式日志](validation/backend-email-auth-regression-3.txt) |
| `git diff --check` | 退出0 |
| `sha256sum -c docs/validation/backend-email-auth-sources.sha256` | 25项源码/测试/配置匹配，退出0；清单SHA-256为`7a3273b419a306398b5ad01a9ed16678c0f34d1f21cf989450305d3bead2ab29` |
| `sha256sum -c docs/validation/ios-local-current-sources.sha256` | 38项仍匹配，退出0；本机模块未变，不重复运行其23项完整结构回归 |

认证测试实际使用Rust进程、隔离PostgreSQL schema、临时HTTP端口和SMTP捕获器，覆盖两用户真实共享、榜单/圈友脱敏、撤回/删除屏障、SMTP失败/未配置/强制STARTTLS拒绝降级、验证过期重放、重复及未知邮箱统一响应、Argon2随机盐/摘要与日志、持久限流、随机凭据来源限流、刷新并发唯一获胜、过期、密码重置后重启旧会话失效、匿名绑定保护及持锁等待期间会话撤销。没有削弱原67项断言；只有迁移版本断言随新增002变为2。

独立reviewer `/root/email_auth_review` 先只读细化认证边界，再复核实现、SMTP/数据库/测试及文档，已确认未发现本模块阻断缺口。最终候选与上述完整回归仍提交外部独立reviewer及Watcher，不能用子reviewer意见冒称外部接受或本轮Watcher已通过。

## 本轮交审与剩余台账

上轮独立业务审计正文已确认`backend_rust_postgres`、`backend_identity`、`backend_social`、`backend_circles`和`ios_local`，但监督结论出现“Module ios_local requires accepted dependencies: backend_identity”。这没有复现业务缺陷。本轮未为此重写实现或篡改状态，而是在真实认证改动及完整回归后，将五个前置与本次`backend_email_auth`一并按依赖顺序列入worker交审的module_ids，供reviewer共同复核，不自行宣称登记状态。

后发Rust/PostgreSQL及邮箱要求覆盖历史Python/SQLite和无需邮箱假设，旧定义不改写；本轮新增认证源码体现覆盖，不回退旧栈。优先认证已落实；最新性能、Swift时间与缓存体验、Mac构建入口要求追加于REQUIREMENTS及[module-additions-08-optimization.json](module-additions-08-optimization.json)，提出`backend_data_access`、`ios_freshness`、`apple_build_validation`三个模块，尚未实现，不虚报收益。

其余未完成模块仍为`ios_network`、`ios_circles`、`https_transport`、`ios_email_auth`、`delivery_validation`、`circles_delivery`、`email_auth_delivery`及三个新增优化模块。本轮没有开展它们，不把邮箱后端交审当作全需求完成或最终持续实例交付。

已知Linux缺少Swift、macOS/Xcode与iOS模拟器的环境未变；没有重复尝试不可用工具。Swift编译、XCTest、系统ATS、签名、真机HealthKit、断网恢复/午夜/圈子切换与视觉交互仍需Mac/iPhone，README保留Mac命令，后续构建入口模块继续交付可执行自动化与人工步骤。本轮没有声明Apple平台已验证。
