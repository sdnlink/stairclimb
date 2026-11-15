# ios_local：已接受后端前置后的交接

本次源版本为 `a036c24f9b514523b8289b991771fcfd09157fb5`，仅提交 `ios_local`。最新独立评审已接受 `backend_identity` 等六个后端模块；直接前置不再处于第26轮文档所述的 pending 状态。不重新提交已接受后端，不修改模块定义、实现、测试、旧证据、Git引用或监督器。`modules=[]` 沿用完整台账。

台账要求本机模块重新验证，但没有未关闭的业务审计问题。实际对比保存检查点 `cde6175e15d33fbf7e4edc1c13d516311b57f351`：`ios/`、`scripts/`、README、需求及前后端规则输入均无差异，命令退出0；42项保存源码摘要全部匹配。因此保留实现及既有聚焦、相关回归证据，不为了新一轮交审重复等价测试发现或重写正确行为。

## 验收覆盖

| 本机模块要求 | 当前可审查实现及测试 |
| --- | --- |
| 原生完整工程、共享scheme和测试target | `ios/StairClimb.xcodeproj/project.pbxproj`、共享 `StairClimb.xcscheme`；保存工程检查确认97个PBX对象、18个应用源文件、7个XCTest源文件及实际测试宿主关联。 |
| 中文楼梯、本人位置、步数/楼层/剩余步数、日区及游戏说明 | `Views/ProgressViewScreen.swift` 展示可视化楼梯和“我”、上海日期；明确100步兑换虚拟楼层，与实际已爬楼层不同。 |
| HealthKit及共同日期汇总 | capability、entitlements、中文用途说明保持；`Health/HealthStepReader.swift` 只请求步数读取，以上海当日半开日区间查询汇总，不写入或删除健康数据。 |
| 授权请求、失败、空数据、前台和跨日 | `App/LocalAppModel.swift` 区分请求完成与读取权限、无可读数据与查询失败；失败保留同日上次值，跨日清空，generation隔离迟到结果；页面前台、刷新及日期计时器接通。 |
| 持久身份与昵称、拒绝共享仍可本地运动 | `Identity/IdentityVault.swift`、`Identity/KeychainStore.swift` 持久保存本机身份；不可读时禁止替换。联网凭证使用独立Keychain项，不以本机UUID授权；本地读取不要求联网、注册或共享。恢复说明区分本机身份与邮箱账号。 |
| 核心测试、日区与演示隔离 | 四份本机XCTest源码共28个方法，覆盖0/99/100/101、最大值、非法汇总、剩余步数、上海午夜、设备日区、Keychain、错误、前台及异步旧响应；无演示模式。 |
| Linux检查、Mac命令与诚实平台边界 | `scripts/check_ios_project.py` 及34项隔离结构回归；README提供实际工程/scheme的Debug、Release及XCTest命令。未声称Apple平台执行通过。 |

## 本次核对与保存的执行证据

本次实际命令、源版本、退出状态、42项摘要结果及旧日志摘要均在 `docs/validation/ios-local-round28-handoff.txt`：

- `git diff --exit-code cde6175e15d33fbf7e4edc1c13d516311b57f351 HEAD -- ios scripts README.md REQUIREMENTS.md backend/src/domain.rs backend/domain.py`：退出0。
- `sha256sum -c docs/validation/ios-local-revalidation-sources.sha256`：42项匹配，退出0。
- 核对保存的 `docs/validation/ios-local-revalidation-focused.txt`：`python3 scripts/check_ios_project.py` 退出0。
- 核对保存的 `docs/validation/ios-local-revalidation-regression.txt`：`python3 -m unittest discover -s scripts/tests -p 'test_*.py' -v`，34项通过，退出0。

后两项是保存的真实运行结果，本次通过输入摘要和只读diff确认仍适用，**没有重新执行，也没有执行Swift测试**。本次新增核对日志SHA-256为 `6160f49dd9c41d7fb6c1df6ad5a3fa87fad9eee12a4af3f1cd7ddb46a91b54d0`。后端无改动，三个固定命令继续保留，由Watcher对候选执行；本次不冒称它们已新运行或已获独立接受。

## 版本8及完整需求边界

继续保留最新授权的Rust/PostgreSQL、邮箱验证、昵称公开/邮箱私密和全程HTTPS，不恢复旧Python/SQLite或明文开发路径。当前本机模块与这些新增功能相容，注册和共享也不作为本机HealthKit读取前置。没有改写历史模块验收。

本次仅完成 `ios_local` 交审。六个后端模块保持已接受；`ios_network`、`ios_circles`、`https_transport`、`ios_email_auth` 仍待各自复核，`ios_freshness`、`apple_build_validation`、`delivery_validation`、`circles_delivery`、`email_auth_delivery` 仍是必交工作，不被本次里程碑替代。最终持续Rust/PostgreSQL/HTTPS实例属于后续交付，本轮没有启动或宣称已交付。

Linux缺少Swift/Xcode/iOS模拟器的已知环境未变，不重试不可用工具。Swift编译、XCTest、签名、系统证书信任、真机HealthKit及视觉交互尚未执行；由Apple验证入口和最终交付模块承接并如实披露。它们没有被静态检查替代，也不是本次新增的代码缺陷。
