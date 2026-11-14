# backend_circles：每日运动圈子验证

本轮完成后端圈子模块，并重新验证受影响的 backend_identity、backend_social。原iOS、本地/联网UI、中文圈子页面、Swift分组测试、最终持续实例和整体交付仍属后续模块，未将后端里程碑当作全部需求完成。

## 先评审与有界变更

用户于2026-11-14追加每日圈子要求；独立 reviewer 先确认覆盖并在 [review-03-amendment.md](review-03-amendment.md) 保留原五模块、追加 backend_circles、ios_circles、circles_delivery。该文件也修复上一轮依赖接受/结论证据交接；原实现没有因此被重写。外部Auto Moniter仍在运行（本轮只读确认PID315810），不修改监督器源码、历史记录或Git引用。

实现变化：`backend/domain.py` 集中1000步参数、日期+区间ID和圈子游标；`backend/storage.py` 添加独立参与选择、派生当前圈子、人数/分页/本人定位；`backend/server.py` 接通实际HTTP。用户默认不参加，旧共享账号升级也不自动入圈。只有有效共享且主动参与者出现，同精确步数/同区间同频道，跨区间同步后自动迁圈。新日每次请求从新日期派生，未同步为0，不改历史、不操作Apple Health原始数据、不依赖定时任务。

新增要求有一项明确覆盖旧默认：删除全部共享步数**同时关闭共享及圈子参与**，而非保持共享开关；退出圈子也停止上传。撤回、退出、删除均在事务内推进持久版本，旧请求不能恢复资格；重新共享榜单不恢复圈子。原社交测试仅调整被新规则影响的两项用例，保留全部原测试名称、认证/日期/幂等/持久化覆盖。README、REQUIREMENTS及API记明新规则。旧验证文件和日志保持原样，仍是当时契约的真实证据。

圈子成员不额外维护可漂移的人数或多圈关系。读取在一个SQLite读快照里完成认证、日期、版本、人数、本人和分页；游标绑定日期、频道区间、版本和页容量。非参加者不返回圈友；旧频道、迁圈、隐私变化或成员变化要求刷新。1人圈只显示本人，不混区或生成假用户。

## 实际聚焦检查

Linux / Python3.12.4。首先运行：

```sh
python3 -m unittest backend.tests.test_circles backend.tests.test_social.SocialHTTPTests.test_delete_all_days_is_persistent_barrier_without_affecting_other_user -v
```

退出0，`Ran 19 tests in 1.361s / OK`（当时新增圈子18项及删除回归1项）。随后新增存储故障、排队跨午夜和撤回旧分页3项，按完整测试名运行这3项，退出0，`Ran 3 tests in 0.129s / OK`。最终圈子套件有21项。

删除新规则使原分页变更用例在删除后仅剩1个公开用户，聚焦执行 `python3 -m unittest backend.tests.test_social.SocialHTTPTests.test_each_public_mutation_invalidates_continuation_and_locate -v` 曾退出1（`next_cursor` 为None）；这是旧夹具人数假设随产品规则变化。增加一个真实已共享用户保留分页场景，并断言被删用户不公开且私人昵称保留，重跑该单项退出0，`Ran 1 test in 0.087s / OK`。没有为此改回新隐私规则或弱化分页断言。

独立reviewer随后检查实际扩展代码，并对隐私竞态、存储故障、排队跨午夜、撤回旧分页执行4项聚焦回归；结果与发现见 [review-03-circles.md](review-03-circles.md)。该复核不是冒称外部Watcher已接受本轮。

## 一次相关完整回归

所有实现和测试定稿后执行一次原固定命令：

```sh
python3 -m unittest discover -s backend/tests -p 'test_*.py' -v
```

退出 **0**，`Ran 64 tests in 3.313s / OK`：原身份/启动23项、社交20项、圈子21项，无重复发现旧套件。完整实际命令、输出、退出状态及源码SHA-256清单见 [backend-circles.txt](validation/backend-circles.txt)。所有测试使用临时SQLite数据库、临时TCP端口和隔离时钟，结束时关闭服务并清理；没有使用正常开发实例。`git diff --check`退出0。

覆盖同区间/同精确步数、999/1000边界、异区间分离、正反迁圈、重复/并发无人数漂移、无今日同步零值、上海年末午夜只读归零重配且历史行不变、旧日/排队请求拒绝、三页无遗漏及非首页本人、游标频道/日期/版本/页容量隔离、参与输入校验、无越权、撤回/退出/两类删除的版本屏障、旧共享身份升级、保留及删除状态重启一致，以及503不冒称成功。

## 源码与限制

基线 `HEAD=104590f708cb184d4eabed2bf466031b3855bdea`，加本轮未提交工作区。测试日志后端源码/测试/配置清单摘要：`b578466e975430860bb63571a792af678f83f2d65db63ae74cd6a5615b61a275`。未暂存、提交、修改Git refs或既有验证记录。原身份测试、启动脚本、配置示例未改。

本后端模块无剩余实现缺口。圈子分页使用全局版本，其他圈子变化也可能保守要求刷新；用户已经保存的数据无法由服务器收回。区间上限标签按完整1000步跨度展示，仍执行1000000上传上限。没有增加即时聊天；追加要求不要求它。没有启动最终持续交付实例，没有执行或宣称通过Swift编译、Xcode签名、HealthKit真机和视觉验证。新增原生圈子页面/Swift规则及Linux工程集成检查已作为必交后续模块保留。
