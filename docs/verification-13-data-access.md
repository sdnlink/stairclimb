# backend_data_access 模块交审

2026-11-15。保留round20已接受的十个模块和原证据；本轮只完成需求版本7（direction `49fde4f401bb4088bdfc657a8c8b1c01`）中已登记的 `backend_data_access`。没有重写模块定义、恢复Python/SQLite正式实现、改动监督器或Git引用。没有新开审计问题需要关闭。

源码版本为 `d01f49dbadd87e0b9b1ceb185a2fce7b872cd28b` 加本轮工作区差异（未暂存/提交）；当前实现、测试、配置及相关文档的精确内容见 `docs/validation/data-access-sources.sha256`。该清单SHA-256为 `afbd1bc8a9fdf6f737d0677f044bf332cd4ea7966c787c12fd0cadd44cf1be06`，实际 `sha256sum -c docs/validation/data-access-sources.sha256` 退出0，输出保存于 `data-access-source-check.txt`。

## 实现与边界

- 新增 `backend/src/pool.rs` 并接通Application及正式/测试HTTP入口；池上限、获取期限、创建预留、租约归还、失败丢弃和握手卡住均有真实检查。配置示例与启动测试验证两个变量显式export；不输出连接凭据。
- `backend/src/storage.rs` 改为用户行锁及取得锁后重认证，公开版本锁移到公开变化的末段。取得用户锁和提交前两次日期检查保留锁等待午夜屏障，失败回滚全事务。
- `backend/src/auth.rs` 使用邮箱摘要的事务级锁和按ID排序的用户锁，验证/重置/登录/刷新/退出/删除统一先锁用户再处理认证子记录；保留邮箱独立注册、旧身份保护、会话轮换、共享及圈子同意。
- 榜单/圈友在PostgreSQL执行COUNT、窗口排名、LIMIT/OFFSET；本人定位最多返回一行。保持repeatable-read、零值用户、并列名次、稳定ID位置、游标/版本失效。迁移003只增加索引及版本记录，导入工具按顺序自动应用；旧数据不清空。
- 新增 `backend/tests/test_data_access.py` 五项实际HTTP测试；Rust四项新增测试覆盖池上限/超时、归还唤醒、失败事务回滚、真实断连替换、无响应握手及非法配置。既有午夜/隐私/邮箱/HTTPS/迁移断言保留。原会话撤销排队测试改为实际用户行锁，与新锁入口一致；没有删掉其等待、撤销及禁止改名断言。
- `scripts/benchmark_data_access.py` 用隔离真实PostgreSQL和临时Rust进程完成1万用户实验；`docs/DATA_ACCESS.md` 保留改前/改后数据、复现方法和局限。榜单延时本次下降，圈友延时本次增加，不声称全面提速。SQL仍可能扫描/排序整个候选集合；应用只接收当前页。

## 本轮实际命令与退出状态

| 命令 | 实际结果 | 当前日志（均在docs/validation） |
| --- | --- | --- |
| `cargo check --locked --manifest-path backend/Cargo.toml --all-targets` | 退出0 | worker工具记录；随后完整Rust回归亦通过 |
| `cargo test --locked --manifest-path backend/Cargo.toml pool -- --nocapture` | 退出0，4项通过 | `data-access-pool-final.txt` |
| 下方10项聚焦命令 | 退出0，Ran 10 tests，OK | `data-access-focused-final.txt` |
| `python3 -m unittest discover -s backend/tests -p 'test_*.py' -v` | 退出0，Ran 108 tests in 122.133s，OK | `data-access-regression.txt` |
| `cargo test --locked --manifest-path backend/Cargo.toml --all-targets` | 退出0，18 passed、0 ignored | `data-access-rust-regression.txt` |
| `cargo fmt --manifest-path backend/Cargo.toml --all -- --check` | 退出0 | `data-access-format.txt`（命令无输出） |
| `python3 scripts/check_ios_project.py` | 退出0，真实工程结构检查通过 | `data-access-ios-structure.txt` |
| `python3 scripts/benchmark_data_access.py --binary .runtime/data-access/before-server` | 退出0，1万用户基线 | `data-access-before.txt` |
| `python3 scripts/benchmark_data_access.py` | 退出0，1万用户当前版本 | `data-access-after-final.txt` |
| `git diff --check`、`git diff --quiet HEAD -- ios` | 均退出0；Swift未修改 | worker工具记录 |
| `python3 -m py_compile backend/tests/pg_fixture.py backend/tests/test_data_access.py scripts/benchmark_data_access.py` | 退出0 | worker工具记录 |

聚焦命令原样：

```sh
python3 -m unittest backend.tests.test_data_access backend.tests.test_launcher backend.tests.test_social.SocialHTTPTests.test_upload_waiting_for_write_lock_rechecks_date_after_midnight backend.tests.test_circles.CirclesHTTPTests.test_pending_upload_over_midnight_cannot_move_into_new_day_channel backend.tests.test_email_auth.EmailAuthTests.test_waiting_write_rechecks_session_after_logout -v
```

108项Python回归只运行一次，直接请求Rust＋真实PostgreSQL，包含隔离邮件捕获、邮箱认证、TLS正反路径、并发共享/圈子/隐私删除、锁等待午夜及持久化；临时schema、服务端口和邮件捕获会清理，不接触开发身份。Rust新增池测试另有真实无响应TCP握手夹具，数据库行为测试仍使用真实PostgreSQL。

初次聚焦命令误写 `EmailAuthHTTPTests` / `CircleHTTPTests` 类名，选择器失败；已更正为实际 `EmailAuthTests` / `CirclesHTTPTests`，最终10项通过。`data-access-focused.txt`保留其中一次失败，不作为通过证据。最初断连测试仅轮询同步Client的 `is_closed`，未驱动其连接收取后端断连；已改为先实际查询并断言失败，再检查关闭/归还/替换。初次失败保存在 `data-access-pool.txt`，最终四项池测试通过。中间成功日志是调试过程记录，不代替最终候选回归。

最终日志SHA-256：

- `data-access-before.txt`: `7cbfb219d4c6591cd9464650a1dc804a6b57c87d45aedee05beaa1ef8b626b87`
- `data-access-after-final.txt`: `44b035a25237114af2628665b2550cb8212283ab483d119d13ee0a41cd3a2564`
- `data-access-focused-final.txt`: `17d65d93e7581a02f6a1548b6a9cf55d4c8d683aa8e8f792bb8df87746d8a245`
- `data-access-pool-final.txt`: `766bc3d495ba6539cd43be641b1d46d8bbde84e6144b0d61f261339084610185`
- `data-access-regression.txt`: `5492dd61c689d7b9180474a505f6427f4b9b3fb084f1d2bd6691fc1ad6cbc6dd`
- `data-access-rust-regression.txt`: `db43701730f9ba2d07475577e0eaed1b04df40764de5863abda33b6b25cfd1b8`

## 交接范围

本模块已实现并验证，提交独立reviewer与Watcher复核；上述执行均是worker验证，未冒称新候选已获接受。完整需求还包括 `ios_freshness`、`apple_build_validation`、`delivery_validation`、`circles_delivery`、`email_auth_delivery`，不在本次模块结论中宣称完成。最终持续Rust/PostgreSQL/HTTPS实例和健康/榜单/圈子探针由交付模块负责；本次临时实验进程已清理。

已知Apple环境限制沿用既有证据：本机仍无Swift/Xcode/iOS模拟器，本轮未重试不可用工具。未执行Swift编译、XCTest、签名、系统信任或真机HealthKit/视觉验证。没有为绕过限制修改HealthKit、ATS、证书信任或测试target。
