# ios_network 有界修复：AUD-3

基于保存的 worker checkpoint `74c25c1c4ac0b2c00119da667f23746c2d63eafd`，本轮仅修复 Debug 本地 IP 的 ATS 配置、对应检查和测试。基线HEAD仍为 `039c2862d38586636fe854883bf6cedda169595d`。后端、HealthKit、同步/隐私协调、工程关联和既有验证记录不改写；没有展开后续 `ios_circles` 或最终集成交付模块。

## AUD-3：接受发现并修复

已只读获取 Apple 官方 DocC 内容，确认 [NSAllowsLocalNetworking](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowslocalnetworking) 对 iOS 17 的说明要求为 IP 连接添加例外；[NSExceptionDomains](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsexceptiondomains) 支持 IPv4、IPv6 和 CIDR，键不含端口。本次修复依据文档和静态检查，未声称已在iOS复现或验证系统放行。

- `ios/StairClimb/Info-Debug.plist` 保留 `NSAllowsLocalNetworking`，在 `NSExceptionDomains` 加入且仅加入 `127.0.0.0/8`、`10.0.0.0/8`、`172.16.0.0/12`、`192.168.0.0/16`、`::1`、`fc00::/7`、`fe80::/16`。每项仅配置 `NSExceptionAllowsInsecureHTTPLoads=true`；无公网地址、任意加载、子域扩展或TLS安全等级放宽。
- `Info-Release.plist` 保持无ATS例外，客户端Release仍拒绝HTTP。`ServiceAddress.swift` 中IPv6首段必须有4个十六进制位才可按 `fc`/`fd` 判断ULA，避免把 `fc::1`（实际首段为00fc）误归为私有地址。`fe80`范围保持与现有客户端一致，没有将例外扩大到整个 `fe80::/10`。
- `scripts/check_ios_project.py` 解析并强制上述精确地址集合、布尔值及仅允许本地HTTP的选项；不再错误要求Debug只有单一全局键。仍拒绝Release任何例外。
- `scripts/tests/test_ios_project.py` 新增7项隔离回归，实际修改临时工程：验证局域网例子192.168.1.3及回环/私有IPv6覆盖；逐个删除7类例外；加入公网、通配符或全地址范围；禁用HTTP许可、增加TLS放宽；加入通用放行；将Debug例外复制到Release，均得到预期结果。
- `NetworkTests.swift` 原地址策略测试增加IPv4边界及IPv6允许/拒绝用例，继续验证同一地址在Release策略下被拒绝。Swift测试源码已交付，但没有执行。
- README更新当前ATS配置和修复记录入口，保留真机局域网及127.0.0.1说明。

## 实际验证

先运行聚焦结构检查，再运行一次相关回归，未重复全量发现。实际命令、完整输出和退出状态保存在 [ios-network-repair.txt](validation/ios-network-repair.txt)：

| 命令 | 结果 |
| --- | --- |
| `python3 scripts/check_ios_project.py` | 退出0，85个对象、14个应用Swift源文件、5个XCTest源文件；关联配置、Debug本地ATS及Release默认ATS通过 |
| `python3 -m unittest discover -s scripts/tests -p 'test_*.py' -v` | 退出0，22项，0.229秒，OK |
| `git diff --check` | 退出0 |

当前修复源码及未变Release对照指纹见 [ios-network-repair-sources.sha256](validation/ios-network-repair-sources.sha256)，清单SHA-256为 `526e87f4062072904a9ac56b909e3c05e9905578cbe68ecee8d3d73e7e5d0103`；日志SHA-256为 `0c4677524c2e71591ab8c8465c58808cbbc896dd66876ca575c6d89510910f1f`。旧 `ios-local`、`ios-network` 清单与日志保留各自历史源码版本，不假装仍是本轮源码指纹。

## AUD-4：保留已知平台限制

Linux缺少Swift、Xcode、macOS和iOS模拟器的事实没有改变。本轮不重试已知不可用构建，不创建替代平台，也不把静态检查或Python HTTP成功冒充Swift编译、XCTest、系统ATS、签名或真机HealthKit成功。README保留对应Mac构建/测试命令及真机验证说明；系统实际ATS连接仍需用户Mac/iPhone环境验证。此为原需求明确允许保留的平台验证限制，不是通过改写源码就能消除的缺陷。AUD-4的审计分类与关闭由独立reviewer处理，worker不自行关闭ID。

新增每日圈子指令与本次窄范围网络修复无冲突；共享同意、日界线、圈子规则及尚待完成的原生圈子/集成交付均保持。固定后端命令未改，由Watcher执行；本轮不冒称reviewer已关闭AUD-3或接受修复。
