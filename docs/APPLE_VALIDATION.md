# Mac 构建、XCTest 与 iPhone 验收

本页交付 `apple_build_validation` 的可执行入口，承接需求版本7的交付优化和版本8的恢复指令。保留原生 Swift/SwiftUI、HealthKit、Keychain、邮箱认证和严格 HTTPS；不改变历史模块定义。当前执行环境为 Linux，下面的 **Mac 构建、XCTest、签名和 iPhone 项目均未执行**，不能把入口或 CI 配置的存在当作平台通过。

## 一次运行完整 Mac 检查

需要完整 Xcode 16+、Python 3.10+，以及在 Xcode 中已安装的 iOS 17+ iPhone 模拟器。只装 Command Line Tools 不够。仓库任意位置可运行：

```sh
python3 scripts/validate_apple.py
# 查看设备；可明确选择一个已有 iPhone 模拟器的 UDID：
xcrun simctl list devices available
python3 scripts/validate_apple.py --device-id <已存在的UDID> --output .runtime/apple-manual-01
```

第一条命令在仓库根目录执行；在其他目录使用脚本的绝对路径。脚本自动选择可用且版本最高的 iPhone 模拟器，不假定机器安装了“iPhone 16”。显式 UDID 不存在/不兼容时失败，不暗中换设备；不会创建、删除、擦除或主动关闭模拟器。Xcode 测试会启动所选模拟器。

执行顺序为现有工程结构/隐私/网络检查、Xcode版本、模拟器列表、Debug构建、Release构建、Debug全部 XCTest。实际工程是 `ios/StairClimb.xcodeproj`，共享 scheme 是 `StairClimb`，关联 `StairClimbTests`；不使用 `only-testing`/`skip-testing` 筛掉用例。两个构建使用 `generic/platform=iOS Simulator`，测试使用所选设备 ID。仅模拟器的签名关闭：`CODE_SIGNING_ALLOWED=NO`；不删除 HealthKit entitlement/capability，不修改 Info.plist、ATS、URLSession 或证书信任。

每次输出到新的 `.runtime/apple-validation/<UTC时间-随机后缀>/`，也可用 `--output` 指定**不存在**的目录。它包含：

- `receipt.json`：Git版本、相关输入SHA-256、平台、实际argv、每条命令退出码、设备及最终状态。
- `structure.log`、`xcode-version.log`、`simulators.log`、`build-debug.log`、`build-release.log`、`xctest.log`、`test-summary.log`。
- `Tests.xcresult` 原始结果包和独立 `DerivedData/`。可在 Xcode 打开结果包检查每项测试。

Xcode 16+ 的 `xcrun xcresulttool get test-results summary --path ...` 返回的测试统计必须有非零通过数量、无失败、无跳过；缺包、格式不兼容、零测试、任一子命令失败或运行期间源码改变，均失败退出。退出码0才代表该次 Mac 模拟器入口完成；入口失败退出2，子命令原始退出码和日志仍保留。不要覆盖旧目录后重用成功收据。只上传或分享审核需要的输出；不要混入 `.runtime` 中的私钥、数据库凭证或捕获邮件。

若找不到Xcode，先用 `xcode-select -p`、`xcodebuild -version` 检查本人Mac上的选择，在 Xcode 设置中安装所需平台/runtime；入口不会下载Xcode、变更全局选择或代签名。Linux直接调用明确失败，不生成 Apple 通过收据。

## macOS workflow

[apple.yml](../.github/workflows/apple.yml) 在 `macos-15` runner 上执行同一个入口；依赖的 iOS 源码、工程、规则或入口变更触发 main push/PR，也支持手动 `workflow_dispatch`。使用 runner 已安装的默认 Xcode 和 iPhone runtime，脚本要求版本至少16且runtime至少iOS17；缺失时如实失败，不下载其他平台或减少测试。只读仓库权限、不持久化 checkout 凭证、不需要开发者Team/签名密钥、SMTP或数据库密钥。

日志、收据和 `.xcresult` 由 `always()` 步骤保存7天，构建或测试失败也保留已有证据。workflow仅为可审查的仓库配置；当前没有推送、触发远程Actions或得到CI结果。若仓库未托管于 GitHub，直接在自有Mac或其他macOS CI运行同一命令即可；不为启用CI注册外部账号。

Apple 的[xcodebuild命令说明](https://developer.apple.com/library/archive/technotes/tn2339/_index.html)与[Xcode 16 xcresulttool更新](https://developer.apple.com/documentation/xcode-release-notes/xcode-16-release-notes)是入口依据。机器实际工具输出和结果包仍是最终执行证据。

## iPhone 验收步骤（尚未执行）

在 Mac 打开工程，选择自己的 Team 和唯一 Bundle ID，保留 HealthKit capability/entitlements。按 [HTTPS配置](HTTPS.md) 启动本项目 Rust + PostgreSQL，使用证书 SAN 覆盖的 Linux 同局域网地址/域名。iPhone 的 `127.0.0.1` 是手机自身。邮件测试只使用 [本地捕获器](EMAIL_AUTH.md) 和自有测试地址，不向真实第三方邮箱投递；密码、邮件凭据及会话不得进入截图、报告或日志。

| 场景 | 操作及应观察的结果 |
| --- | --- |
| 证书与加密 | 仅传送公开CA证书，核对指纹，按HTTPS文档在自己的设备安装并开启信任；正确域名/IP可连。未信任CA、SAN不匹配或过期证书应连接失败，`http://` 地址应被拒绝。不能用忽略信任错误修复；记录iOS版本及每项实际结果。 |
| HealthKit首次授权 | 清楚识别自己的测试安装，首次读取显示中文用途说明；允许读取后走路/有真实步数再刷新，核对上海当日汇总、虚拟楼梯和每100步一层/剩余步数。明确不是健康App实际爬楼层。 |
| 无可读数据/失败 | 在系统健康权限中取消读取后再次读取，不应声称已识别拒绝；“无可读数据”与查询失败区分。失败保留带缓存提示的同日上次值/时间，不能伪装成功0步或上传不确定的0值。授权在系统中改变后回前台可重新读取。 |
| 未登录/不同意 | 不登录或不共享仍可本地运动。完成真实邮件验证再登录，昵称不默认邮箱；登录/验证不自动同意共享或加入圈子。榜单和圈友不包含邮箱、邮件凭据或认证信息。 |
| 联网/分页 | 用三个或更多独立测试账号主动共享并同步，看到真实昵称、步数、虚拟楼层、排名和本人；加载全部页和定位本人。需更多成员时可运行现有隔离HTTPS探针验证分页，不把探针数据注入开发身份。 |
| 断网与恢复 | 先成功读取/同步/刷新，记下时间，再断Wi-Fi/服务并重试。失败不推进成功时间，不把旧值标成今日新同步；圈友失败隐藏旧成员并标过期。重连后手动重读再同步，成功时才更新时间；重复点击不重复累计。 |
| 自动迁圈 | 同一区间的两个真实汇总账号同频道；用实际健康数据或已有隔离HTTP测试覆盖999/1000及双向跨区间。实际App同步前隐藏旧成员，确认后展示新频道及原因、1000步规则，人数正确，无虚构成员。不要增加生产改步数/改时入口。 |
| 上海午夜/回前台 | 在真实上海23:59至00:00保持前台，另一次让App后台跨午夜再返回；设置手机不同显示时区再复核。日期、步数和频道都按上海；昨日成功记录/成员失效，重新读取后才能同步，未同步的公开用户为0。历史不被覆盖为0，不删除Apple健康原始数据。不可修改开发服务器全局时间来制造结果；受控跨日可另运行已有隔离探针。 |
| 撤回/退出/删除 | 联网时撤回/退出圈子应停止上传并移除成员，重启不自动恢复；重新参加需主动同意。断网删除显示待确认，不冒称完成，重连后确认。删除共享步数保留账号但关闭共享/圈子，删除账号连邮箱认证及记录一并删除。退出登录不等于删除已公开历史。 |
| Keychain与认证恢复 | 重启后使用同一身份；会话到期后正常刷新，刷新响应丢失不重放旧凭据，要求重登录。密码重置后旧会话失效。只移除本机凭证和重装不能保证恢复本机/旧匿名身份；不要在生产身份上执行破坏性验收。 |
| 视觉与辅助功能 | 在小/大屏及较大字体、VoiceOver检查中文文本、楼梯上的本人、楼层/剩余步数、加载/错误状态、缓存提示和成功时间；无裁切或按钮不可达。由实际设备记录问题，源码检查不代表通过。 |

每次Mac/iPhone验收记录源版本、设备型号、系统/Xcode版本、时间、实际命令/退出码、通过/失败/未执行及脱敏证据。模拟器XCTest通过也不能证明真机HealthKit、签名、系统证书信任或视觉体验通过；这些是待设备执行的验证限制，不应通过降低安全策略绕过。


## IPA 打包流程

新增[Build iOS IPA workflow](../.github/workflows/ipa.yml)，在同一完整模拟器验证入口通过后执行真机架构Release归档并打包。支持无签名和Development/Ad Hoc/App Store手动签名导出，现有GitHub证书变量的完整映射、产物下载及安装限制见[IPA打包](IPA_BUILD.md)。当前无远程Actions执行记录，不能以配置文件存在代替真实构建通过。
