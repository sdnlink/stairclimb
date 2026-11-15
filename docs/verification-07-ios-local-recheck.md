# ios_local 当前版本交审

本轮推进台账中下一个未接受模块 `ios_local`。起始版本为 `3cf9e4c2d2a71d6af49ff57b3d9d2fca493183e2`；保留已接受的 `backend_rust_postgres`、`backend_identity`、`backend_social`、`backend_circles`，不改业务源码、测试、历史验证记录或监督器。模块定义沿用现有台账，结论使用 `modules=[]`，避免重写不可变定义。

已逐项复核保存的本机实现：实际 Xcode 应用与 XCTest target、共享 scheme、中文可视化楼梯、100步换层与剩余步数、上海日界线、HealthKit capability/entitlements/中文用途说明、仅当日汇总读取、首次请求/无可读数据/错误/前台/午夜状态，以及 Keychain 本机身份和昵称。读取失败保留同日旧值并标为失败，跨日清除旧值，查询 generation 阻止旧结果覆盖新日。本机进度不依赖网络账号或共享同意；没有演示模式。联网凭证通过现有 `NetworkVault` 使用独立 Keychain 项，不以本机 UUID 授权后端。

独立 reviewer `/root/ios_local_review` 已先只读复核上述实现、工程及测试，未发现需要修改的本模块实现缺口，建议保留业务源码。其结论不代表外部 Watcher 已登记接受。现有4个本地 Swift 测试文件的28个测试方法覆盖换算、不同设备日区下的上海午夜、身份和健康读取状态及异步旧响应；这些是已关联 XCTest target 的测试源码，**本轮没有执行 Swift/XCTest**。

## 本轮实际检查

完整命令、输出、源版本和退出状态见 [ios-local-current.txt](validation/ios-local-current.txt)，当前检查输入的 SHA-256 清单见 [ios-local-current-sources.sha256](validation/ios-local-current-sources.sha256)。历史清单不改写。

| 实际命令 | 结果 |
| --- | --- |
| `python3 scripts/check_ios_project.py` | 退出0；91个PBX对象，16个应用源文件、6个XCTest源文件；工程引用、测试关联、配置、HealthKit、中文隐私说明及Swift/Rust规则一致 |
| `python3 -m unittest discover -s scripts/tests -p 'test_*.py' -v` | 退出0；23项通过，使用临时工程副本验证缺失/错误引用、scheme、HealthKit、ATS及规则漂移的拒绝行为 |
| `git diff --check` | 退出0 |

先运行聚焦工程检查，再运行一次相关回归。未修改后端，不重复运行三个固定后端验收命令；它们仍原样保留，交由外部 Watcher 对候选执行。本轮不冒称它们已经针对新候选执行，也不把历史测试当成本轮运行。

## 最新要求与交付边界

Rust/PostgreSQL覆盖旧正式Python/SQLite方案，原生Swift/SwiftUI不变。本轮本机模块无联网上传，故不需要为重新交审改写已接受后端。邮箱验证、Argon2id会话与找回、隐私约束、严格HTTPS和本地可信CA仍是必交增量：由已登记的 `backend_email_auth`、`https_transport`、`ios_email_auth`、`email_auth_delivery` 承接。当前匿名联网入口和Debug局域网HTTP属于旧实现，**不符合新增认证/全程HTTPS完成条件**，本轮没有将它们当作新要求已满足。不得将本机编号当作邮箱或账号恢复凭证。

除本次提交的 `ios_local` 外，未接受的 `ios_network`、`ios_circles`、`delivery_validation`、`circles_delivery` 和以上四个新增模块继续保留，不以本机模块里程碑代替全需求完成。最终持续Rust/PostgreSQL/HTTPS实例仍由最终交付模块提供；本轮没有启动最终实例或宣称整体交付。

Linux缺少Swift、macOS/Xcode及iOS模拟器的既有事实未变，本轮不重复尝试已知不可用工具，也不创建替代平台。Swift编译、XCTest、系统ATS、签名、真机HealthKit与视觉交互仍需Mac/iPhone验证；[README](../README.md)的实际工程/scheme对应Mac命令和限制保持。Linux静态检查不能代替这些平台验证。
