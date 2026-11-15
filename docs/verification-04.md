# ios_local：原生工程与本机进度

本轮仅实现待办 `ios_local`，不把模块里程碑视为整体交付。基线 HEAD 为 `039c2862d38586636fe854883bf6cedda169595d`。先读取现有 README、需求追加节、后端规则和 API，保留已接受的 `backend_identity`、`backend_social`、`backend_circles` 实现与全部历史验证文件。进程列表确认外部 Auto Moniter 的 resume/review-first 流程正在监督此工作区，本轮没有启动重复监督器或修改其源码/历史/Git引用。

## 本模块交付

- `ios/StairClimb.xcodeproj`：完整传统 Xcode 工程，实际应用/单元测试 target、依赖、共享 `StairClimb` scheme、HealthKit/Security framework、资源、独立 Debug/Release 配置。无需工程生成器。
- `Core/StepRules.swift`：100步/层、0至1000000步整数上限、剩余步数；HealthKit非有限/负数/超界结果报错，不截断为成功最大值。合法小数汇总向下取整为完整步数。1000步圈宽集中保留，与后端契约检查一致；本轮不宣称圈子匹配或页面已交付。
- `Core/ShanghaiDay.swift`：固定上海 Gregorian 日历、半开日区间和读取时间格式，不依赖设备日区。
- `Health/HealthStepReader.swift`：只请求 `.stepCount` 读取，按上海当日区间执行 `.cumulativeSum` 汇总，不保存、修改或删除 Apple Health 数据；没有演示模式、原始样本上传、定位或网络请求。
- `App/LocalAppModel.swift`：区分初次请求、请求中、读取中、不可用、成功、暂无可读数据和失败。只记住请求流程完成过，不把它解释成授权成功。失败不制造零值；保留且标记同日上次结果。前台/刷新查询，前台定时检查上海换日；跨日先清空旧快照，再读取，新旧查询以 generation 隔离。
- `Identity/`：UUID与本机昵称整体写入 Keychain，`WhenUnlockedThisDeviceOnly`，不跨设备同步。UserDefaults只有非敏感请求流程标记；安全存储不可读或损坏时禁止替换身份。昵称规则按Unicode码点与后端一致。本机UUID不是服务器认证凭证；真实注册、服务器昵称和凭证接入属于下一模块 `ios_network`，届时复用安全存储。
- `Views/ProgressViewScreen.swift`：中文楼梯卡片突出“我”，显示步数、虚拟楼层、距下一层、上海日期与读取时间；失败/无数据/未读取明确区分。提供本机昵称编辑、下拉更新和健康访问入口，并说明游戏楼层不同于健康App实际已爬楼层。没有假排行榜或虚构圈友。
- `StairClimbTests/`：28个Swift测试方法已关联实际XCTest target，包含边界、日期/日区、错误、持久身份、Keychain真实写读、前台读取、异步午夜及并发读取隔离。**只交付测试源码，未执行这些测试。**

HealthKit授权语义依据 Apple [Authorizing access to health data](https://developer.apple.com/documentation/healthkit/authorizing-access-to-health-data)：不把读取拒绝与零数据可靠区分，也不使用写权限状态推断读取权限。查询使用 Apple [predicateForSamples](https://developer.apple.com/documentation/healthkit/hkquery/predicateforsamples(withstart:end:options:)) 的区间谓词。本次浏览搜索通道返回 capability_not_supported，改用官方DocC JSON只读获取成功，没有因此伪造平台结果。

## 实际Linux检查

完整命令、输出及退出状态在 [ios-local.txt](validation/ios-local.txt)。

| 命令 | 实际结果 |
| --- | --- |
| `python3 scripts/check_ios_project.py` | 退出0；解析72个PBX对象，9个应用Swift文件、4个XCTest文件；检查工程引用图、scheme、测试host/依赖、源文件/资源关联、图标、HealthKit、隐私用途、Debug/Release ATS及后端常量一致性 |
| `python3 -m unittest discover -s scripts/tests -p 'test_*.py' -v` | 退出0，15项，OK；使用临时副本验证破坏文件/关联/配置时会报错 |
| `git diff --check` | 退出0 |

先完成聚焦工程检查，再执行检查器回归；首轮通过后调整了Swift日期显示和状态保护，最终日志对应更新后的源码。没有重复运行无变化的后端完整发现：本轮未更改后端，沿用已接受的64项证据，Watcher自行运行固定交付命令。固定命令在README及原需求中原样保留。

源码版本见 [ios-local-sources.sha256](validation/ios-local-sources.sha256)，覆盖全部iOS文件、检查器及其回归和对照用后端规则。清单SHA-256：`dd94b85e4f2e778c8f82f2fc2d98b3de05c2a9088cae80898330739fe20cf3a4`；实际日志SHA-256：`a32cc93609acebdd072c88e76ab7846e1f799e2a47107cd6bc6bfadb69e34538`。文档不参与源码清单，避免循环指纹。

## 平台限制与后续范围

环境实测Linux，`swift`和`xcodebuild`均不存在。未执行Swift编译、XCTest、模拟器、签名、真机HealthKit和视觉/辅助功能验证；Linux工程检查不能替代这些验证。[README](../README.md)提供真实工程、scheme对应的Mac Debug/Release构建和iPhone模拟器测试命令，以及真机签名/健康权限说明。Keychain重装保留和无邮箱/手机号的找回限制已在App与README说明。

新增产品指令与本模块没有冲突：已落实上海午夜/前台/刷新更新、保留Apple原始数据、集中1000步参数，并保留圈子主动同意及真实联网页面为独立必交模块。没有静默随机分组、强制公开或抢先声称圈子UI完成。

当前模块提交独立reviewer复核；不冒称reviewer或Watcher已接受本轮。其余必交模块保持 `ios_network`、`ios_circles`、`delivery_validation`、`circles_delivery`。最终持续后端实例须在全部集成完成后交付，当前没有冒称已完成最终启动。
