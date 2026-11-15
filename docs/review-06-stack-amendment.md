# Rust＋PostgreSQL 需求变更确认

2026-11-15，独立 reviewer `/root/stack_review` 已只读检查当前后端、测试、启动脚本及需求，确认可开始有界迁移。用户后发的「服务端用rust」「数据库用pgsql」覆盖原先正式 Python/SQLite 方案；iOS 仍用原生 Swift/SwiftUI。历史验收记录不改写，也不作为新栈通过证据。

新增前置模块 `backend_rust_postgres`：真实 Rust 可执行文件、`backend/Cargo.toml` / `Cargo.lock`、真实 PostgreSQL、版本化迁移、隔离数据库运行方式、SQLite 在线备份及逐字段导入校验。迁移保留 HTTP/Swift 契约、认证摘要、同意版本屏障、累计幂等、分页快照、上海日界线、每100步一层、每1000步分圈和全部隐私删除语义。

原 `backend_identity`、`backend_social`、`backend_circles` 的业务标准保留，但正式数据库和事务替换成 PostgreSQL，增加对此前置模块的依赖，必须以新栈真实证据重新复核。原64项场景和关键断言保留，SQLite 文件/锁故障改用真实 PostgreSQL 关系故障及事务锁。测试时钟只在 Rust 测试构建开放文件注入，生产 HTTP 和 CLI 不开放改时。

固定命令继续包含：

```sh
python3 -m unittest discover -s backend/tests -p 'test_*.py' -v
cargo test --locked --manifest-path backend/Cargo.toml --all-targets
cargo fmt --manifest-path backend/Cargo.toml --all -- --check
```

Rust 测试须有非零规则、数据库、重启持久化及并发隐私覆盖；Python HTTP 测试必须连到 Rust＋PostgreSQL，不能用历史服务代替。Swift 契约脚本、Linux 工程规则检查和最终启动步骤也要迁移。

其余模块 `ios_local`、`ios_network`、`ios_circles`、`delivery_validation`、`circles_delivery` 继续保留，后端依赖链变更后按顺序报告复核，不能篡改监督器状态。已有 Swift 界面不因迁移无关重写。Mac/iPhone 的已知平台验证限制继续披露。

本阶段只提交后端迁移及兼容验证里程碑；Swift 圈子页面和最终持续实例属于后续模块。外部 Auto Moniter 已运行（只读进程检查确认），没有修改其源码、审计记录或 Git 引用。
