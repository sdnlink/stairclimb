# 迁移候选结论格式修复

本轮只恢复已完成Rust/PostgreSQL迁移候选的合法交审，不因结论格式失败重写业务代码。

监督器报告的直接原因是 `Module plan rejected: module backend_identity definition cannot change; preserve its original acceptance criteria`；独立reviewer另曾把ios_local中「设备日区不同的情况」改写成其他措辞，导致invalid module plan。这些是不可变定义合并失败，不是业务测试失败。

按最新人工指令，结论modules采用增量追加：[module-additions-07.json](module-additions-07.json)仅声明五个新模块，键仅为id/title/acceptance/depends_on，不附带files/checks，也不重述既有八个模块定义。既有backend_identity、backend_social、backend_circles、ios_local、ios_network、ios_circles、delivery_validation、circles_delivery继续保留，不改写历史定义、监督器state、旧日志或Git引用。

原始历史定义中的Python/SQLite、无需邮箱及本地HTTP默认，被后发Rust/PostgreSQL、邮箱验证及全程HTTPS授权覆盖。通过追加模块承接覆盖关系，不能为了合并定义回退实现。早期需求说明中提到「增加原模块依赖」应理解为实施顺序，不能据此修改监督器保存的depends_on。

本轮实际执行 `sha256sum -c docs/validation/backend-rust-postgres-sources.sha256`，退出0，24项全部匹配。当前HEAD为`039c2862d38586636fe854883bf6cedda169595d`；清单SHA-256仍为`238f905e096e9b299b84bdf247b440c622909e7dd8316935b14a9f5e7d831fd9`。业务输入未变，未重复执行发现式测试。

已有真实证据保留：固定Python命令67项、固定cargo test共12项（含4项实际PostgreSQL）、cargo fmt、真实三用户HTTP契约及23项结构测试均退出0，详见[迁移验证](verification-06-rust-postgres.md)及其原始日志。这些是worker执行记录，不冒称Watcher已经接受或执行了新候选。

本轮提交范围仍为backend_rust_postgres，并以同一新栈证据依次提交backend_identity、backend_social、backend_circles重新复核。邮箱认证、全程HTTPS、Swift邮箱界面、Swift圈子及最终集成交付尚未完成；新模块提案不代表这些已实现。当前匿名认证和本地HTTP是迁移阶段保存的行为，不能作为满足最新邮箱与HTTPS要求的最终交付。

Linux缺少Apple平台的已有事实保留，不重试不可用构建、不声称Swift编译、XCTest、签名、系统ATS或真机HealthKit通过。本轮没有修改服务实现、测试断言或历史验证证据。
