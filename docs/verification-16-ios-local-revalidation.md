# ios_local 当前栈重新验证

基线为 `664ff47bf0d43c516353e5832b7be3f14d5248de`。本轮联合提交 `backend_identity` 与其上层 `ios_local`，不改后端、数据库、监督器、Git引用或历史证据。模块定义沿用台账，`modules=[]`。第24轮独立业务评审接受了六个后端模块，但本次权威台账仍将它们标为 pending、要求重新验证；历史业务结论不等于当前登记状态。本轮仅核对本机模块及其直接前置 `backend_identity`，其余模块保留在台账。

台账将本机模块标为 pending，原因为重新验证，未有复现回归。本轮对比保存检查点 `24b762d93ba9e2b8537949c2fe3a4f05d266a9e0` 与基线：本机 App、Health、Identity、换算/上海日期、楼梯页面以及四份本机 XCTest 源文件均无差异。因此复用实现与既有测试，不重写已经核验的行为。

唯一应用改动是 `ios/StairClimb/Views/ProgressViewScreen.swift` 的恢复说明：明确“本机身份不绑定邮箱、不能跨设备找回”，并指明联网邮箱账号可在今日楼层榜登录或找回密码，避免旧文案“没有邮箱”与最新版功能混淆。没有改变授权、健康读取、持久化或联网行为；这是可逆文案澄清，不新增镜像实现的测试。

## 覆盖与实际检查

- 实际工程包含应用与 XCTest target、共享 scheme、源文件/资源关联、测试宿主及依赖；当前为97个PBX对象、18个应用源文件、7个XCTest源文件。
- 中文可视化楼梯突出本人虚拟楼层，展示步数、当前层、下一层剩余步数与上海日期，明确100步兑换1个游戏楼层，不是实际已爬楼层。
- HealthKit capability、entitlements、中文隐私说明及仅步数读取保持；上海日界线查询当日汇总，无演示数据、健康写入或原始明细上传。
- 本机模型处理首次请求、不可用、请求/查询失败、无可读数据、前台刷新与午夜；失败保留同日上次值并标识，跨日清除昨日值，generation隔离迟到结果。未声称可识别读取拒绝。
- 本机UUID/昵称经Keychain持久化，读取失败不覆盖旧身份；不依赖联网注册或共享同意。联网会话使用独立Keychain项，不以本机UUID授权。
- 四份现有本机测试源码共28个测试方法：换算4、上海日期4、身份5、健康状态/异步15；均关联实际测试target。**本轮未执行这些Swift测试**。

先聚焦工程检查，再运行一次相关回归，实际日志均保留命令、基线与退出状态：

| 命令 | 结果 | 当前日志 |
| --- | --- | --- |
| `python3 scripts/check_ios_project.py` | 退出0，全部结构检查通过 | `docs/validation/ios-local-revalidation-focused.txt` |
| `python3 -m unittest discover -s scripts/tests -p 'test_*.py' -v` | 退出0，34项通过；临时工程副本验证错误配置会被拒绝 | `docs/validation/ios-local-revalidation-regression.txt` |
| `sha256sum -c docs/validation/ios-local-revalidation-sources.sha256` | 退出0，42项匹配 | `docs/validation/ios-local-revalidation-source-check.txt` |

源码清单涵盖整个iOS工程、检查器及其测试、Swift/Rust规则依赖与README；清单SHA-256为 `28f8e4111321f40f67264758a5d658c3a086ec3458520d983abf65d2e8e02cee`。后端未变，本轮不重复三个固定后端检查；命令保留，由Watcher对候选执行。没有冒称外部reviewer或Watcher接受。

## 最新授权与完整需求边界

版本8恢复授权继续版本7的Rust/PostgreSQL、邮箱认证、隐私和全程HTTPS，覆盖早期冲突假设，未新增产品行为或放宽检查。本轮不改历史模块定义，不恢复匿名注册或Debug明文路径；工程检查同时核对当前严格HTTPS、默认系统信任及TLS1.2下限。身份页说明现在与邮箱认证实际能力一致。本机数据仍可独立查看，账号注册不替代健康共享或圈子参与的主动同意。

已重新盘点完整台账：本轮联合交审 `backend_identity`、`ios_local`；`backend_social`、`backend_circles`、`backend_rust_postgres`、`backend_email_auth`、`backend_data_access` 保留第24轮业务评审和未变源码证据，当前 pending 登记留待监督流程处理；`ios_network`、`ios_circles`、`https_transport`、`ios_email_auth` 的保存实现仍待各自重新验证；`ios_freshness`、`apple_build_validation`、`delivery_validation`、`circles_delivery`、`email_auth_delivery` 继续为后续必交模块。本次没有启动最终持续实例或宣称整个需求完成。

## 交审报告修复与直接前置核对

本次续接修正的是报告遗漏直接前置以及混淆历史接受与当前登记状态的问题，没有新的业务失败。保留上文已完成的聚焦工程检查和34项相关回归：源码清单仍匹配，不重复等价发现命令。只修改本交审文档并新增 `docs/validation/ios-local-dependency-revalidation.txt`；保存的一处应用文案改动和全部既有日志均未改写。

实际只读对比第24轮业务检查点 `7b940eb9fbb839396a1437351e0abff1df257608` 与当前后端、脚本、README、需求及API/数据库说明，`git diff --exit-code` 退出0。实际执行两份已保存清单检查：`sha256sum -c docs/validation/pool-timing-sources.sha256` 退出0、32项匹配；`sha256sum -c docs/validation/ios-local-revalidation-sources.sha256` 退出0、42项匹配。当前日志保留完整命令、源版本及退出状态。

对 `backend_identity` 的源码核对覆盖：`backend/src/domain.rs` 的上海日界线、100步规则和输入范围；`backend/src/storage.rs` 的随机凭证摘要、认证后用户行锁及锁后重新认证、昵称校验、共享版本原子屏障；`backend/src/http.rs` 的4096字节上限、重复JSON字段/未知字段/身份查询拒绝；三份版本化迁移、启动脚本、显式export配置及对应真实HTTP测试。当前正式匿名注册已被邮箱要求覆盖并关闭，旧身份仅保留绑定及私有隐私操作，不回退Python/SQLite。

只读核对第24轮Watcher收据及三个原始日志，均为退出0、收据 `complete=true`、`source_changed=false`，对应 tree `c05be07fe1278f8edd4e338e1677ce29643ce65fc921d63fc4ef2ba7a618e21d`：Python实际112项（含身份/共享屏障、重启、请求限制及真实Rust/PostgreSQL启动），Rust实际18项、无忽略，格式检查通过。日志SHA-256与独立评审所列值一致，详见新增日志。它们是未变后端的历史验证；没有声称本轮已运行固定检查或得到新Watcher接受。当前候选仍由Watcher执行三个固定命令。

Linux缺少Swift/Xcode/iOS模拟器的既有环境事实未变，不重复调用已知不可用工具，也不以静态检查冒充Apple验证。Swift编译、XCTest、签名、系统证书信任、真机HealthKit及视觉交互尚未执行。实际工程、scheme对应的Debug/Release构建及XCTest命令保留在README“iOS 本机进度模块”；这些平台限制继续交由Apple验证及最终交付模块明确承接，不阻断本轮可在Linux验证的本机源码交付。
