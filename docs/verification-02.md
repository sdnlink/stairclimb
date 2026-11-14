# backend_social 验证记录

本记录由 worker 生成，提交独立 reviewer 复核；不是 reviewer 接受结论，也不代替 Watcher 固定检查。此前接受的 backend_identity 及原始验证日志保持保留。

## 交付边界与实现

本轮完成累计同步、排行榜和隐私删除模块。修改 `backend/domain.py`、`backend/storage.py`、`backend/server.py`，新增 `backend/tests/test_social.py`；更新 README 和 API 文档。不扩展到尚未完成的 ios_local、ios_network 或 delivery_validation。

- SQLite 追加 `daily_steps` 表，按用户与上海日期唯一保存累计快照，允许健康数据修正后降低累计值；重复快照不累加，也不改变保存时间或榜单版本。共享同意、版本验证和写入在同一事务中执行。
- 同步在获取写锁后读取隔离注入的时钟并验证当日日期，避免排队跨午夜后接受旧日数据。生产 HTTP/CLI 不提供改时能力。
- 真实榜单包括仍共享但尚未同步的零值账号，排除未共享/撤回账号。并列采用竞赛名次、用户 ID 稳定排序；独立 position 用于分页和本人定位。版本绑定游标，变化/跨日返回409要求刷新。所有榜单读取在同一个 SQLite 读事务快照中完成。
- 全部共享步数删除覆盖所有日期并推进持久共享版本，阻止此前的延迟上传写回；保留主动共享开关。账号删除级联清除记录并使原凭证失效。撤回隐藏保留记录，再次主动共享会重新公开仍保留的当日值；文档明确这一规则和删除入口的区别。
- 复用已验证的身份认证、共享状态和错误处理，没有改写原有身份测试、启动配置、启动脚本或既有验证日志。新增升级用例模拟旧版仅有 users/metadata 的数据库，确认身份及共享版本保留。

## 实际验证

环境：Linux / Python 3.12.4。本工作区外部监督流程仍在运行，已只读确认 Auto Moniter 主进程 PID 315810；没有启动重复监督实例、修改监督器源码或其历史记录。

先运行新增行为的针对性检查：

```sh
python3 -m unittest backend.tests.test_social -v
```

当时已加入的17项测试全部通过，退出0，`Ran 17 tests in 1.072s / OK`。随后补充升级、存储故障和从未共享账号删除的检查，执行：

```sh
python3 -m unittest backend.tests.test_social.SocialHTTPTests.test_existing_identity_schema_upgrades_without_resetting_consent backend.tests.test_social.SocialHTTPTests.test_storage_outage_does_not_claim_successful_upload_or_delete backend.tests.test_social.SocialHTTPTests.test_never_shared_account_can_delete_and_clock_is_not_remotely_configurable -v
```

退出0，`Ran 3 tests in 0.095s / OK`。最终该模块包含20项新增HTTP测试。

实现与测试定稿后，只运行一次相关完整回归：

```sh
python3 -m unittest discover -s backend/tests -p 'test_*.py' -v
```

退出 **0**，`Ran 43 tests in 1.712s / OK`（保留的23项 + 新增20项，无重复发现身份用例）。完整命令、源码 SHA-256 清单、实际 stdout/stderr 和退出状态保存在 [backend-social.txt](validation/backend-social.txt)。`git diff --check` 也退出0。所有服务均使用临时数据库及 `port=0` 分配的真实 TCP 端口，结束时关闭服务器、回收线程和临时目录，不接触开发实例。

HTTP覆盖多用户注册、主动同意、同步、全榜及非首页本人定位、改名、重复/降低快照、0/99/100/101及最大值、并列/零值、三页无遗漏遍历、日期与分页非法输入、未知字段/原始明细/越权、未认证、撤回、跨日、删除和重建服务后的持久化。隐私竞态分别将上传与撤回、删步数、删账号并发，确认完成隐私操作后旧上传无法恢复公开/已删内容；另验证写锁阻塞跨午夜会拒绝昨日快照，以及服务故障返回503且不显示写入/删除成功。

## 源码版本与限制

验证基线 `HEAD=104590f708cb184d4eabed2bf466031b3855bdea`，测试对应本轮未提交工作区。日志中的后端源码/测试/启动配置 SHA-256 清单摘要为 `41bd35611662bcbe1c0196bb6aeaf917370cf6edc9cb45175aae085a091da1c6`。本轮未暂存、提交或修改 Git refs。

该模块无未完成的实现项。iOS 工程、HealthKit、Keychain、联网界面、最终持续运行实例及整体交付验证仍属原有后续模块；本次没有启动最终交付实例，也没有宣称完整原始需求已完成。Linux 缺少 Apple 工具链的事实不变，未执行 Swift 编译、签名、真机 HealthKit 或视觉验证。榜单持续变化时可能需重新分页，客户端应按API规则刷新；MVP 不保留历史公开快照。用户已看到或另存的数据不能由服务器收回。
