# Rust＋PostgreSQL 迁移验证

本轮交付范围为 `backend_rust_postgres`，并用新栈重新验证 `backend_identity`、`backend_social`、`backend_circles` 的原业务行为。按最新授权，正式 Python/SQLite 方案已被 Rust/PostgreSQL 替代；Swift/SwiftUI 工程及此前独立核验的界面、HealthKit、Keychain和ATS行为保留。技术栈先行独立确认见 [需求复核](review-06-stack-amendment.md)。没有修改 Auto Moniter、审计状态或Git引用，没有暂存/提交。

源版本：基准 HEAD `039c2862d38586636fe854883bf6cedda169595d` 加本轮工作区变更。24项实现、规则参考、迁移、测试及脚本的当前指纹见 [源码清单](validation/backend-rust-postgres-sources.sha256)，清单 SHA-256：`238f905e096e9b299b84bdf247b440c622909e7dd8316935b14a9f5e7d831fd9`。历史 Python 和 iOS 日志均未改写，不用于宣称新栈通过。

## 实现与隔离

- `backend/Cargo.toml`、`Cargo.lock`、`src/**` 为直接连接 PostgreSQL 的 Rust HTTP服务，无Python包装或代理。默认二进制为 `stairclimb-server`，启动脚本最终exec此二进制。启动测试实际核对 `/proc/<PID>/exe`。
- `migrations/001_initial.sql` 是事务迁移1，包含主外键、唯一约束和取值约束，支持空库启动和已有表的增量补齐。所有业务写事务先锁同一metadata行，再认证、检查同意版本及写入；读列表使用REPEATABLE READ同一快照。上传取得锁后重新采样上海日期，等待锁跨午夜的昨日请求被拒绝。
- 真实任务 PostgreSQL 17 容器为 `stairclimb-pg-fe5e36b647`，仅绑定 `127.0.0.1:32807`。镜像 `postgres:17-bookworm` 拉取摘要 `sha256:40865bc877a289da75963d97d72b59633f639fc5af7a4e856bfa3714cae5b536`。项目卷保留，凭证仅存被忽略的600权限文件，日志/本文不包含连接串。
- 每个HTTP测试启动单独Rust进程，HTTP为port=0，数据库为独立随机`test_<UUID>` schema；测试清理进程和schema，不访问public开发身份。数据库故障用真实关系暂时不可用模拟；锁测试通过pg_stat_activity确认实际等待行锁。Rust测试也创建/清理实际PostgreSQL schema，不跳过数据库测试。
- 时钟文件仅由`test-support`测试二进制读取；生产入口拒绝改时参数及测试时钟环境。Rust单元测试的内存时钟仅在cfg(test)存在，无生产HTTP改时接口。
- 迁移前默认`.runtime`目录不存在，项目未发现开发SQLite文件。导入工具仍以SQLite online backup保留一致备份，在非空目标拒绝并回滚，逐字段核对身份、凭证摘要、同意、历史步数、参与和分页版本。3项真实导入测试验证旧凭证继续可用、Rust服务重建持久、旧身份默认不参加及非空目标不清库。

## 实际命令与结果

| 检查 | 退出状态与结果 | 日志 |
| --- | --- | --- |
| 首轮 `python3 -m unittest discover -s backend/tests -p 'test_*.py' -v` | 1，67项，11个error（含子场景） | [保留失败](validation/backend-rust-postgres-http-01.txt) |
| 修复后6项聚焦unittest（完整命令见日志） | 0，6项，7.080s | [聚焦](validation/backend-rust-postgres-focused.txt) |
| 修复后原样固定Python命令 | 0，67项，65.961s，OK | [回归](validation/backend-rust-postgres-http-02.txt) |
| `cargo test --locked --manifest-path backend/Cargo.toml --all-targets` | 0，12项，含4项真实数据库测试，无忽略 | [Rust](validation/backend-rust-postgres-native.txt) |
| `cargo fmt --manifest-path backend/Cargo.toml --all -- --check` | 0 | [Rust](validation/backend-rust-postgres-native.txt) |
| `python3 scripts/verify_ios_api.py` | 0，3身份真实HTTP契约/跨日/分页/隐私/重启/503 | [集成](validation/backend-rust-postgres-integration.txt) |
| `python3 scripts/check_ios_project.py` | 0，实际PBX引用、scheme、target、权限、ATS及Rust/Swift规则核对 | [集成](validation/backend-rust-postgres-integration.txt) |
| `python3 -m unittest discover -s scripts/tests -p 'test_*.py' -v` | 0，23项 | [集成](validation/backend-rust-postgres-integration.txt) |
| `git diff --check` | 0 | [集成](validation/backend-rust-postgres-integration.txt) |

AST只读对比基准和当前测试方法：原64项全部保留，无丢失；增加3项导入测试。SQLite专有检查替换成真实PostgreSQL检查，关键业务断言保留。4项Python规则参考测试之外，规则也由Rust测试直接覆盖。

首轮失败定位：10个error来自Python夹具共用clock.new的并发replace竞态，现通过实例锁串行原子写入；另1个error为超大请求被拒绝后TCP立即关闭导致response.read收到重置。现先发送FIN，并仅在有限时长/65536字节内排空后续输入，保留请求体4096上限；新增Rust24次真实TCP重复测试确保JSON 413可读。修复后先跑原失败路径及跨日聚焦，再进行一次固定回归，没有用删除断言或改写失败日志消除问题。

## 继续交付的边界

本模块不是全部应用完成。`ios_circles`、`delivery_validation`、`circles_delivery`仍须继续；保存的Swift圈子页面不在本轮宣称已验收。最终持续Rust实例的健康/排行/圈子及PID/停止命令属于后续交付模块。本轮临时HTTP实例均清理，任务PostgreSQL可供后续复用；停止仅它：`python3 scripts/postgres_dev.py stop`。

Linux仍没有Mac/Xcode/iOS模拟器，本轮没有Swift编译、XCTest运行、签名、系统ATS、真机HealthKit或视觉交互验证。README保留实际Mac命令和这些限制；静态检查不能替代平台执行。独立reviewer和Watcher的最终接受由外部监督流程记录，本文只记worker执行事实。
