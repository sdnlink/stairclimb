# backend_circles 独立实现复核

本记录由先行需求 reviewer 在 worker 请求下独立检查本轮实现后生成；不是 Watcher 固定检查结果。先行需求及模块覆盖见 `review-03-amendment.md`，原五模块和新增三个模块保留。

## 结论与范围

已检查 `backend/domain.py`、`backend/storage.py`、`backend/server.py`、`backend/tests/test_circles.py`、本轮有界调整的 `backend/tests/test_social.py`、`docs/API.md` 和 `REQUIREMENTS.md`。未发现阻止提交 backend_circles 的实现问题；worker 随后完成一次相关完整回归，已只读核实实际日志与当前源码清单，见下方补记。本次有限独立复核接受 backend_identity、backend_social、backend_circles 的当前实现，外部 Watcher 检查仍独立记录。本次 reviewer 没有执行完整发现命令、启动持续交付服务或修改业务实现。

- 规则集中定义为 `CIRCLE_BAND_STEPS=1000`，频道由上海日期与区间决定。0/999、1000/1999及最大合法步数边界有测试；原100步一层和最大上传值不扩大。
- 参与状态使用新增单行主键表，旧账号不回填为参加。参与写入与共享/同步/删除共用 `BEGIN IMMEDIATE` 和 `consent_revision`。新参与要求已有共享同意；关闭、撤回、删除都使旧请求版本失效。显式退出圈子也关闭共享，API已清楚告知；这满足新增“停止上传/自动加入”要求。只再次开启排行榜共享不恢复圈子参与。
- 步数删除现关闭共享、移除参加、推进版本，账号删除通过外键清理参与与全部日期记录。旧契约中保留共享开关的断言按新增产品规则有界调整；新分页保留用户夹具维持真实多页检查，没有削弱变更失效断言。旧验证日志未改写。
- 读取认证身份、日界线、全局版本、本人参与、当日快照、人数、排序位置及分页均处于同一个 SQLite 读事务。成员动态派生、没有可漂移的多圈成员关系或人数计数；同步跨区立即只属于新圈，新日无行取0且不写昨日行。人数小则保留真实单人圈，不混区或生成假用户。
- 圈子游标独立绑定日期版本、频道区间、页容量和位置，跨圈/跨日/变化返回409，缺损及越界422。接口不接受客户端目标身份、任意频道或历史日期。未参加返回空圈，撤回后的旧继续游标409，不泄露原成员页。本人定位使用同样稳定位置和区间。
- 新HTTP测试覆盖分组边界、精确相同步数、未同步、三页遍历、非首页本人、重复及并发、午夜归零重配、旧日拒绝、隐私删除、旧请求、服务重启、旧数据库迁移和服务故障。既有写锁跨午夜规则未移除。

## 本次 reviewer 实际执行

仅执行以下四项聚焦HTTP检查：

```sh
python3 -m unittest backend.tests.test_circles.CirclesHTTPTests.test_concurrent_participation_upload_and_privacy_changes_are_serialized backend.tests.test_circles.CirclesHTTPTests.test_storage_failure_does_not_claim_join_or_exit_succeeded backend.tests.test_circles.CirclesHTTPTests.test_pending_upload_over_midnight_cannot_move_into_new_day_channel backend.tests.test_circles.CirclesHTTPTests.test_revoked_viewer_cannot_continue_old_circle_page -v
```

实际退出0，`Ran 4 tests in 0.282s / OK`。均使用既有临时 SQLite/临时端口HTTP夹具并清理，不接触开发实例。本次 reviewer 只新增本评审记录，未暂存、提交、修改 Git refs 或监督器文件。

源码基线 HEAD=`104590f708cb184d4eabed2bf466031b3855bdea`。检查时文件SHA-256：

```text
376c34bde852cdf6112202be26597768176a352282bcdb45e7e82a3f46919687 backend/domain.py
3497525f93ac2200281df2063733b2a32a53a840f32f0c9940a652754f95781e backend/storage.py
746d01f4531f10531dd978cf4d41b11267b225eb3b595aaf8310eaa4ae88727e backend/server.py
2910e260d538cbd9650a22afaa44184d83db60460f52763a69aba75defecb6d9 backend/tests/test_circles.py
6e4a438cc9adf93bab4345eaa8b80abf595a6dbf29c930be283dfe753ceac925 backend/tests/test_social.py
0c28c457678d8e5abebaedbfbe5fb5ffe23a8f5f837e4e3d912fd422440360b4 docs/API.md
403f667f23e31f5074d01a98f02199f57a6891b0f17af5d8cf3fd2e656a35cc4 REQUIREMENTS.md
```

本轮仅是圈子后端范围。iOS原生页面、HealthKit/Keychain、前台午夜更新、Swift测试、Linux工程检查和最终集成交付仍由原有及新增后续模块完成；本记录不把这些未完成项当成后端模块阻塞，也不宣称整体需求或Apple平台验证通过。

## 完整回归证据补记

worker 完成完整回归后，本 reviewer 只读检查 `docs/validation/backend-circles.txt` 与 `docs/verification-03.md`。固定命令为 `python3 -m unittest discover -s backend/tests -p 'test_*.py' -v`，实际退出0，`Ran 64 tests in 3.313s / OK`。核对日志的10项当前源码/测试/启动配置 SHA-256 均匹配，清单摘要为 `b578466e975430860bb63571a792af678f83f2d65db63ae74cd6a5615b61a275`；日志SHA-256为 `33ef14d6e5d508bb0e3b014237c7752bc4d43cecf907ac737fcc44272f16f520`。上列代码检查SHA-256不变，没有为日志检查重跑测试或修改实现。

该结果关闭本 reviewer 此前的“完整回归尚待worker完成”时间性缺口。依赖模块共同确认，避免把 backend_identity 的依赖接受遗漏误作 backend_social 或 backend_circles 的业务缺陷；原AUD-1、AUD-2保持既有关闭状态，没有新建或重开问题。当前后端三个模块可提交外部监督复核，其余原始及新增iOS/集成模块继续保留待完成。
