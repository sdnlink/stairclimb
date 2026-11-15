# 保存候选复核与模块交接

2026-11-15 恢复保存候选；源码基线仍为 `0d9a059e025f7d352604d9325900e68d1d81827c` 加现有工作区差异，需求版本7。当前实现、测试与历史日志全部保留。本次仅新增此交接记录；未暂存、提交、修改 Git 引用或监督器文件。

本次实际执行：

| 命令 | 退出状态及结果 |
| --- | --- |
| `sha256sum -c docs/validation/ios-email-network-sources.sha256` | 0；55项全部一致 |
| `sha256sum docs/validation/ios-email-network-sources.sha256 docs/validation/ios-email-network-focused.txt docs/validation/ios-email-network-focused-2.txt docs/validation/ios-email-network-regression.txt` | 0；摘要与原交审记录一致 |
| `python3 scripts/check_ios_project.py` | 0；97个工程对象、18个应用源码和7个XCTest源码；实际target、共享scheme、HealthKit、中文用途说明、严格HTTPS、TLS1.2及认证接线通过 |
| `git diff --check` | 0 |

只读逐项计算历史清单中的 SHA-256：`https-sources.sha256` 为46/56匹配，其中后端22/22匹配；`ios-local-current-sources.sha256` 为26/38匹配。历史清单的差异对应已保存的邮箱接入、HTTPS和工程检查增量，不将旧清单冒充当前完整指纹。当前55项清单摘要为 `69a78d331389dfc22f419cd00b4f2074c8860788b7d61fa92fcbc0ec6b8198b2`。

已核对并复用保存的聚焦及一次相关回归，**本次未重跑这些测试**：

- `python3 scripts/verify_ios_api.py`：`docs/validation/ios-email-network-focused-2.txt` 保存退出0。真实Rust/PostgreSQL、受验证CA的HTTPS及隔离SMTP完成三个独立邮箱账号、验证登录、共享、分页/本人、跨日、撤回删除、持久化、会话刷新/找回/退出及错误路径。日志摘要 `dc35e8b25ea080bab05a5f92991f8f629c73a64f67fc10fc8438ff8867758ca5`。
- `python3 -m unittest backend.tests.test_email_auth backend.tests.test_https scripts.tests.test_ios_project -v`：`docs/validation/ios-email-network-regression.txt` 保存66项通过、退出0，摘要 `10e691b0597dfbb3b2c6397a683c547e392a39bac7edc63b38586bb0bde66c10`。
- `docs/validation/ios-email-network-focused.txt` 后段保存首次探针错误断言导致的退出1，不整体引用为通过。成功结果使用上述 `focused-2.txt`；原失败和修正说明保留于 `docs/verification-11-ios-email-network.md`。

本次提交 `ios_network`、`ios_email_auth` 模块。为满足依赖联合复核，结论同时列出已核验的前置 `backend_rust_postgres`、`backend_identity`、`backend_social`、`backend_circles`、`backend_email_auth`、`https_transport`、`ios_local`。依据为当前源码指纹、`docs/verification-06-rust-postgres.md`、`docs/verification-09-email-binding-repair.md`、`docs/verification-10-https.md`、`docs/verification-07-ios-local-recheck.md` 及本候选交审记录。当前独立评审输入仍是HTTPS模块接受结果，没有新增要求修复本候选的业务发现；不因旧评审或登记格式问题修改业务实现。worker不自行关闭AUD编号或宣称监督器已登记接受。

全需求仍保留 `ios_circles`、`backend_data_access`、`ios_freshness`、`apple_build_validation`、`delivery_validation`、`circles_delivery`、`email_auth_delivery`。本次模块交接不扩展这些范围。三个固定检查继续由Watcher执行；没有重跑等价全量发现命令。

Apple工具链环境未变化：Swift编译、XCTest、系统ATS/URLSession、Keychain、签名、真机HealthKit和视觉交互均未执行。Linux工程检查及后端HTTPS契约结果不能代替Apple平台验证。最终持续Rust/PostgreSQL/HTTPS实例与PID、日志、停止方式属于最终交付模块，本次没有启动或宣称交付该实例。
