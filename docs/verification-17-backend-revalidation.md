# 后端依赖链重新验证

需求版本8；源码基线为 `c43523f470acefddba92aa97d413a4e07c37ddec`。独立评审曾接受 `backend_identity`、`ios_local`，但本次输入的权威台账仍标记为 pending、要求重新验证；不能以历史评审正文代替登记。本次按依赖顺序联合提交实际核验的六个后端模块：`backend_rust_postgres`、`backend_identity`、`backend_social`、`backend_circles`、`backend_email_auth`、`backend_data_access`，补齐直接前置 `backend_identity`。保留 `ios_local` 已验证实现，本次不重复提交它。未发现新的业务故障；AUD记录的关闭权仍属于独立reviewer。

保存的首次核验只新增本文及三份验证日志；本次续接修正本文并新增一份交接核对日志，详见末节。未修改业务实现、测试、历史证据、监督器、Git暂存区或引用。实际 `git diff --exit-code 7b940eb9fbb839396a1437351e0abff1df257608 -- backend scripts README.md REQUIREMENTS.md docs/API.md docs/DATA_ACCESS.md docs/EMAIL_AUTH.md docs/HTTPS.md` 退出0。实际 `sha256sum -c docs/validation/pool-timing-sources.sha256` 退出0、32项全部匹配。当前实现与已审查的后端候选一致，未发现需要重写的行为。命令、完整源版本及历史收据核对保存在 [源码检查日志](validation/backend-current-revalidation-source-check.txt)。

## 当前实现与验收覆盖

| 模块 | 本轮核对的实现及现有有意义测试 |
| --- | --- |
| `backend_rust_postgres` | Cargo工程与锁文件、正式Rust入口、直接PostgreSQL连接、001至003事务迁移、生产禁用测试时钟；隔离schema/临时端口夹具实际启动Rust。迁移测试通过真实HTTP核对导入的凭证摘要、昵称、同意版本、历史、圈子及服务重启，拒绝非空目标，不清库。 |
| `backend_identity` | `domain.rs`集中定义100步换算、上海日界线及输入边界；`storage.rs`以凭证摘要授权本人、用户行锁后重新认证、原子推进共享版本，关闭即使原已关闭也建立持久屏障。`http.rs`限制4096字节请求体、拒绝重复JSON字段与身份参数；配置显式export，启动脚本运行真实Rust。当前邮箱要求覆盖正式匿名注册，未恢复旧入口。现有身份HTTP回归包含错误输入、延迟开启、重启及启动配置。 |
| `backend_social` | `storage.rs` 取得用户行锁后重新鉴权和校验同意版本，按用户/日期唯一替换累计值，等待锁后及提交前重验上海日期；repeatable-read分页、并列排名、零值、本人定位与版本失效；撤回、删步数和删账号的持久屏障。现有真实HTTP测试包含重复/并发、越权、跨日、服务故障和重启。 |
| `backend_circles` | 当前权威日期及1000步区间派生频道与人数；独立主动参与，退出/撤回/删除阻断旧请求。真实HTTP测试覆盖999/1000、精确同值、双向迁圈、分页本人、午夜、历史保留、重启及故障。 |
| `backend_email_auth` | `auth.rs` 的Argon2id、随机盐、摘要化一次性凭据/会话、持久限流、刷新轮换及撤销；邮箱归属和旧设备双重证明，不接管或合并旧身份；账号删除级联。`mail.rs` 生产强制TLS/STARTTLS，捕获仅限回环，未配置/失败不冒称投递。邮箱测试实际读取隔离SMTP邮件，覆盖未同意不上传、公开模型脱敏、找回/退出/重启、限流/重放以及AUD-5、AUD-8既有修复。 |
| `backend_data_access` | `pool.rs` 包含创建预留的连接上限、获取期限、租约归还及断连丢弃；用户行锁→子记录→公开版本锁的顺序保持。PostgreSQL执行COUNT、窗口排名、LIMIT/OFFSET，本人查询返回一行；003索引保留。五项聚焦HTTP检查验证耗尽503与恢复、独立用户进展、排队后同意重验、257名零值用户遍历/本人/分页失效。 |

连接池真实断连、回滚、复用、握手卡住和80ms耗尽断言继续保留在Rust测试中，没有削弱AUD-10修复。既有一万用户改前/改后实验与局限仍见 [数据库访问说明](DATA_ACCESS.md)、[基线实验](validation/data-access-before.txt)、[当前实验](validation/data-access-after-final.txt)；本轮没有重复压测或声称新的性能收益。数据库仍可能扫描/排序候选集合，深OFFSET有成本；优化约束应用每页接收人数及连接数，不承诺查询常数时间。

## 本轮实际验证

先执行聚焦检查，再运行一次相关回归；测试使用真实Rust、独立PostgreSQL schema、临时端口与回环邮件捕获器，结束清理测试资源，不向外部邮箱发送邮件。

- `python3 -m unittest backend.tests.test_data_access -v`：退出0，5项通过，5.384秒；[聚焦日志](validation/backend-current-revalidation-focused.txt)。
- `python3 -m unittest backend.tests.test_social backend.tests.test_circles backend.tests.test_email_auth backend.tests.test_migration -v`：退出0，73项通过，195.850秒；仅运行一次，[回归日志](validation/backend-current-revalidation-regression.txt)。
- `git diff --check`：退出0；业务/测试/配置与上述保存检查点的比较仍无差异。保存的首次核验新增四个证据文件，没有实现或测试增量。

同时只读核对第26轮Watcher收据和三份原始日志摘要：`complete=true`、`source_changed=false`，tree为 `6ff55847a4f615e553df90929dee2a3133b523d7decc6f3aa8f08d8b21d81ee0`。当时固定Python命令112项、Cargo全target命令18项且无忽略、格式检查均退出0。核对结果在本轮源码检查日志中。后端源码未变，复用该历史Rust/格式证据，不把它描述为本轮重新执行或新的Watcher接受。三个固定命令保持原样，当前候选仍由Watcher运行。

## 授权、依赖与交付边界

后发Rust/PostgreSQL、邮箱归属验证和全程HTTPS继续覆盖原Python/SQLite、无需邮箱及局域网明文假设；原模块定义保持，`modules=[]`。本轮没有恢复匿名正式注册、移除健康共享/圈子主动同意、放宽证书信任或修改固定检查。版本8要求恢复保存工作、补齐pending前置接受名单，因此联合提交上述六个实际核验模块，而不因登记差异重写已验证实现。

已重新盘点全台账：`ios_network`、`ios_circles`、`https_transport`、`ios_email_auth` 保存实现仍待重新验证；`ios_freshness`、`apple_build_validation`、`delivery_validation`、`circles_delivery`、`email_auth_delivery` 继续必交。本轮不扩展至这些模块，也不宣称整个需求完成或最终持续实例已交付。没有修改Auto Moniter源码或运行状态，没有提交/暂存、部署公网或购买服务。

既有Linux环境缺少Swift/Xcode/iOS模拟器的事实未变，不重复尝试不可用平台。Swift编译、XCTest、签名、系统证书信任及真机HealthKit/视觉交互仍未执行；Mac/iPhone验证继续由平台入口和最终交付模块承接。此限制不构成本轮六个后端模块的实现缺口。

## 续接的报告修正与证据核对

本次续接仅修正本文中“前置已登记接受”和遗漏 `backend_identity` 的表述，新增 [交接核对日志](validation/backend-report-handoff.txt)。上节5项聚焦、73项相关回归以及第26轮三个固定检查均为保存的实际结果；本次没有重跑测试或构建，没有改写这些原始日志。核对源码清单32项、相对保存检查点的业务差异、两份当前栈回归日志的源版本/计数/退出状态，以及第26轮原始日志摘要，均通过、退出0。仅证据和结论格式发生变化，不以报告修复为由编辑正确实现；当前候选仍交由独立reviewer复核和Watcher执行固定检查。
