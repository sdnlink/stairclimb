# Core Motion 本机计步

当前iOS使用`CMPedometer`，不读取Apple健康，也不合并Apple Watch或其他设备的步数。后台暂停期间由系统提供已有计步记录，应用返回前台重新查询。虚拟楼层仍为每100步一层；服务器继续使用上海日期、当日累计快照和1000步圈子区间，Rust/PostgreSQL接口不变。

## 用户行为

首次打开只显示说明，不主动读取。点击“开启本机计步”后，以短时系统计步查询触发“运动与健身”权限请求；这次查询结果仅用于完成授权流程，不参与当天累计。授权成功后再查询上海00:00至当前时间的步数。系统已允许时不会重复发起授权探测；拒绝或受限制时显示明确提示。

旧HealthKit请求标记不会当作Core Motion授权。升级后需重新主动开启本机计步；既有Keychain身份、登录、共享意图和服务器历史不被删除。只有主动同意共享后，才按原有规则上传本次成功读取的当天汇总。

“我的楼梯”前台每15秒刷新，也支持下拉和按钮刷新；返回前台补查。每次查询都替换当天累计，不将旧结果相加。上海午夜立即清除昨天的展示，异步旧日返回不能写入今天。日界线使用Asia/Shanghai，不跟随手机显示时区。

拒绝运动权限、设备不支持、系统限制、请求未完成、无数据和真实0步分别处理。查询失败保留标为缓存的同日上次结果，既不伪造0步也不上传旧值。无可读数据可在本地显示说明和临时0步，不能作为成功步数上传；明确返回的真实0步可上传。

## 设备和后台边界

需要支持计步的真实iPhone并携带手机运动。模拟器和替代传感器测试不代表真实步数可读。系统提供的历史查询通常限于最近7天，本项目只查询今天；不补造更早的未同步历史。应用挂起或被系统终止时，不保证应用代码持续执行、界面刷新或按时上传；回前台再查询和同步。没有申请GPS、音频或其他无关后台模式。

仅上传当天`date/steps/expected_revision`，不上传原始加速度、位置信息或系统运动样本。不需要注册账号也可本机查看。服务端只是展示客户端汇总，不具备独立验证实际步数或识别作弊的能力。

## 工程与权限

- `ios/StairClimb/Motion/MotionStepReader.swift`：系统计步器、可注入查询接口、授权检查与上海当天查询。
- `LocalAppModel`继续处理缓存、新查询、失败与跨日屏障。
- Debug/Release均提供中文`NSMotionUsageDescription`，链接CoreMotion与Security。
- 移除HealthKit framework、SystemCapability、HealthKit entitlement及健康读写用途说明。保留空entitlements文件作为工程签名入口，签名导出仍核对团队、显式App ID、描述文件类型、设备及最终签名。
- 使用不含HealthKit的合法Development描述文件即可打包；旧文件如果本身还有HealthKit授权，不影响其作为描述文件使用，但本应用最终签名不能再请求HealthKit。

此前`Profile must enable the HealthKit capability`门禁已移除，因为当前程序不使用HealthKit；这不是绕过仍被使用的能力。导出收据记录`step_source: core-motion`、`no_healthkit_entitlement_verified: true`和`exported_signature_verified: true`。正常Apple签名和目标iPhone的UDID仍必须具备。

## 测试与验收

新增`MotionStepReaderTests`9项，覆盖上海时区和查询边界、累计值不叠加、首次权限探测丢弃、拒绝/限制/不可用不查询、授权后拒绝、不请求权限时不自动弹窗、空值/真实0/错误分离、查询中撤销权限、未知错误不泄露。LocalAppModel另测旧HealthKit标记不迁移，并保留原来的午夜、缓存、并发、撤回上传等测试。全部Swift源文件与测试均在原target内。

Linux已通过68项脚本回归、完整25个Swift文件语法解析、PBX关联/权限检查，以及actionlint工作流检查；语法与脚本检查不等于Swift编译或XCTest执行。本次Core Motion迁移尚无Mac或真机执行结果，需在新提交的Actions完成全部XCTest，再用Development IPA进行设备验收。

真机步骤：

1. 安装新版本Development包，确认描述文件包含此iPhone，必要时按系统提示开启开发者模式。
2. 点击开启本机计步，允许运动与健身，步数来自此iPhone而非Apple健康跨设备汇总。
3. 携带手机行走，前台等待或刷新，核对步数、虚拟楼层及动画；同一个累计值重复读取不增加步数。
4. 后台一段时间后返回，核对当天补查与主动共享者同步；检查跨1000步区间后的自动迁圈。
5. 在设置中关闭运动与健身访问，重试应显示权限关闭，不能上传缓存；再允许后返回读取恢复。
6. 不登录、不共享仍可计步；退出或隐私操作继续停止上传，聊天保持关闭。
7. 上海午夜和手机其他时区验证日期切换；不修改系统原始运动数据，也不删除服务器历史。

## Apple 官方依据

- [CMPedometer](https://developer.apple.com/documentation/coremotion/cmpedometer)
- [运动访问用途说明](https://developer.apple.com/documentation/bundleresources/information-property-list/nsmotionusagedescription)
- [历史查询](https://developer.apple.com/documentation/coremotion/cmpedometer/querypedometerdata(from:to:withhandler:))
- [实时更新及应用挂起行为](https://developer.apple.com/documentation/coremotion/cmpedometer/startupdates(from:withhandler:))
