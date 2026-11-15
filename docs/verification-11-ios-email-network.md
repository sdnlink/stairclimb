# ios_network / ios_email_auth 本轮交审

本轮基于 HEAD `0d9a059e025f7d352604d9325900e68d1d81827c` 的工作区增量。需求版本7（`0f0b02550ca7868604bdb2b3c4a4bd9d0d0887041c6572f956de80a4d3c87f37`）。只完成中文邮箱认证接入及其正式联网依赖 `ios_network`，提交两个模块供独立复核，不宣称整个需求完成。不改既有模块定义、监督器状态或历史记录，不暂存、不提交、不改Git引用。

按后发授权优先完成邮箱＋严格HTTPS，替代旧匿名注册入口；正式Rust/PostgreSQL代码、HealthKit、系统TLS信任及所有历史验证文件保持原样。邮箱账号接入与原联网模块共用身份、上传及隐私屏障，必须一并核验，而非把正式已禁用的匿名注册当作可用联网。`ios_circles`、`backend_data_access`、`ios_freshness`、`apple_build_validation`、`delivery_validation`、`circles_delivery`、`email_auth_delivery` 仍留待后续模块，不在本轮扩展实现范围。此前已接受的 backend_identity/backend_social/backend_circles/backend_rust_postgres/backend_email_auth/https_transport/ios_local 不重写。

## 当前变更

- `ios/StairClimb/Network/EmailAuth.swift`、`Views/EmailAccountView.swift`：中文注册、邮箱实际凭据验证、重发、登录、忘记/重置密码、旧身份绑定及邮箱主人独立恢复。邮件提交不代表收件/验证，验证仅在`completed:true`后显示完成，随后另行登录。昵称不从邮箱生成，密码及邮件凭据仅在本次请求内存中使用；提交、关闭表单、切后台清空输入。邮箱只在本人账号设置按需读取，不持久化。
- `APIClient.swift`增加认证字段及脱敏错误映射，保留HTTPS、TLS1.2下限、系统证书信任、禁重定向及请求超时。`NetworkVault.swift`只增加必要刷新/到期/未确认状态，原匿名Keychain格式兼容；不保存邮箱、密码或邮件凭据。
- `SocialModel.swift`用邮箱会话替代匿名注册。到期前30秒串行轮换、先持久化刷新不确定屏障；丢失响应/崩溃后不能重放刷新凭据，需登录同账号。读取最多刷新重试一次，写请求不自动重放。Keychain失败保留内存中新凭据供安全重存。不同用户登录不能覆盖当前身份；同账号重新登录保留未完成撤回、删除或退出，登录不开启健康共享或圈子。
- 退出先本机停传并持久化待完成意图，等待在途操作后请求`logout-all`；只有服务器确认才能移除会话并显示完成。网络失败不冒称退出/删除完成。原撤回、删除版本屏障、仅上传本次成功的同日汇总、分页/定位、跨日和缓存错误处理保留。`SocialView.swift`接通实际邮箱表单并更新退出/删除/找回说明。
- `EmailAuthTests.swift`新增18项Swift测试方法，`NetworkTests.swift`补1项退出/上传竞态；保留原健康/隐私/分页断言。原匿名注册安全保存用例迁为邮箱登录安全保存，同一测试目的。`CircleTests.swift`仅将已有夹具更新为正式邮箱会话，无删减原断言。工程增加两个应用源文件和一个测试文件，实际target共18个应用源文件、7个XCTest源文件。
- `scripts/verify_ios_api.py`升级为受验证本地CA的真实HTTPS＋隔离SMTP＋Rust/PostgreSQL契约验证。`check_ios_project.py`及其五项新增错误配置回归检查匿名旁路、表单关联、测试target、后台清除和密码持久化风险。README、EMAIL_AUTH、服务配置示例更新为实际入口。

## 实际检查

| 命令 | 结果 | 当前证据 |
| --- | --- | --- |
| `python3 scripts/check_ios_project.py` | 退出0；18应用＋7测试源码/真实target、HealthKit、严格HTTPS及认证接线通过 | `docs/validation/ios-email-network-focused.txt`第一段 |
| `python3 scripts/verify_ios_api.py` | 修正脚本断言后退出0 | `docs/validation/ios-email-network-focused-2.txt` |
| `python3 -m unittest backend.tests.test_email_auth backend.tests.test_https scripts.tests.test_ios_project -v` | 退出0，66项，114.318秒，OK | `docs/validation/ios-email-network-regression.txt` |
| `sha256sum -c docs/validation/ios-email-network-sources.sha256` | 退出0，55项一致 | 当前源码指纹清单 |
| `git diff --check` | 退出0 | 本轮最终差异检查 |

聚焦HTTPS探针以三个独立邮箱账号真实完成注册→读取捕获邮件→验证→登录，不允许匿名绕过；确认未同意不能上传。继续验证累计幂等、三页遍历及非首页本人、改名/分页失效、未同步零值、身份篡改、上海午夜、旧日拒绝、撤回/旧请求屏障、步数删除和账号删除、Rust重建后的持久化、数据库故障503。新增刷新轮换及重放、捕获找回邮件后重置及旧会话失效、重置重放、重新登录仍不共享、退出全部会话、邮箱关联删除及SMTP失败。所有TLS连接验证CA/域名；探针无对外邮件能力，临时TLS/SMTP端口、证书、邮件及随机schema均清理。

第一次聚焦脚本退出1：错误地期待刷新重放返回`unauthorized`，实际既有`backend/src/auth.rs`及`backend/tests/test_email_auth.py`契约是`authentication_failed`。只修正脚本断言并重跑成功，没有因错误断言修改后端。保留首次失败日志，不能引用为通过。回归中的TLS1.0/1.1弃用警告来自明确拒绝旧协议的测试，不是测试失败。

本轮未重复运行三个Watcher固定命令；它们保持原样，由监督流程对候选执行。相关回归不冒称固定全量检查或独立reviewer结论。

源码清单SHA-256：`69a78d331389dfc22f419cd00b4f2074c8860788b7d61fa92fcbc0ec6b8198b2`。首次聚焦日志：`1eb097de0828bce4a2fd158e9d5f03ead132d1e10c493b0912dd90b55f5eb0ed`；成功HTTPS探针：`dc35e8b25ea080bab05a5f92991f8f629c73a64f67fc10fc8438ff8867758ca5`；66项回归：`10e691b0597dfbb3b2c6397a683c547e392a39bac7edc63b38586bb0bde66c10`。

## 验证边界

已知Linux环境无Swift/Xcode/模拟器，未重复探测未变化环境，也未制造替代平台。本轮Swift测试为实际target中可在Mac运行的测试源码，**未执行Swift编译、XCTest、系统ATS/URLSession、Keychain真机、签名、HealthKit或视觉交互验证**。真实HTTPS探针和Python结构回归不能替代这些检查。Mac命令仍为README中对应真实工程和共享scheme的`xcodebuild ... build/test`；后续apple_build_validation交付可执行入口，最终交付保留iPhone操作步骤。

本轮没有启动最终持续服务；所有新增验证实例均为测试专用，最终运行的Rust/PostgreSQL/HTTPS实例、健康/排行榜/圈子实请求及PID/日志/停止方法仍属于最终交付模块，不以本次两个模块交审代替。未修改Auto Moniter源码、状态或记录，未对公网部署或向真实外部邮箱发送邮件。
