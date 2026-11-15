# 历史：Apple健康连接排查

**当前版本已改为Core Motion本机计步，本页其余内容仅记录迁移前的故障。无需HealthKit权限或能力，当前排查请查看[本机计步](MOTION_COUNTING.md)。**

# Apple 健康连接排查与无数据处理

“连接 Apple 健康”使用本机HealthKit读取步数，不需要联网账号、共享圈子或后端在线。当前尚未取得本次故障设备、iOS版本、安装方式和具体错误码，不能认定用户这次故障一定由权限或签名导致。

## 本次代码修复

`HKStatisticsQuery`没有匹配的可读样本时可能返回`HKError.errorNoData`。此前代码把所有查询错误当作“读取失败”；现在仅将HealthKit域的errorNoData映射为`noReadableData`，与空统计结果一致。明确的真实0步仍是成功汇总；数据库锁定、授权错误和其他同编号不同域错误不会被转成0步或空结果。无可读数据不能证明用户拒绝读取权限，不作为有效健康汇总上传服务器。

错误提示区分健康不可用、系统/MDM限制、设备锁定、尚未完成访问流程、操作不被允许及用户取消。未知错误保留安全的系统错误码，不显示NSError.userInfo或原始错误描述。查询失败保留同日缓存并标过期；成功读取和跨日时清除旧错误编号。

“我的楼梯”新增“健康连接帮助”：说明健康App权限检查、解锁重试、重新请求、应用设置入口和重新签名后的HealthKit能力要求。仅显示iOS、应用版本、构建号、Bundle ID和错误编号供排查；不发送诊断信息或健康样本。

## 真机确认

1. 使用支持健康功能的iPhone，保持解锁并停留前台，在Apple健康中确认今天有步数记录。
2. 在健康App头像下的App或App和服务中选择爬楼梯，检查步数读取；系统设置菜单名称可能随iOS变化。授权请求完成不代表可以判断用户是否同意读取。
3. 如果通过第三方工具重新签名安装，检查签名保留`com.apple.developer.healthkit`；显式App ID和描述文件也应启用HealthKit。仅有P12证书不等于具备健康能力。不使用未签名包进行真机验收。
4. 提供页面完整提示、错误编号、iOS版本和安装方式，继续区分权限请求失败与查询失败。无须提供步数截图、原始健康数据、账号或证书。

## 验证

新增5项Swift XCTest覆盖errorNoData与真实0步区分、真实失败不变空结果、错误信息不泄露、设备锁定保留旧数据、授权请求失败不标记完成。Linux静态工程检查、4个修改Swift文件语法检查和61项脚本回归通过；HealthStepReader原有quantityType强制解包语法被tree-sitter标记缺失“!”的已知解析限制仍在，其他修改没有语法错误。上述不代替Swift编译、XCTest执行或真机HealthKit验证。新增Swift测试须在下一次macOS Actions中实际运行。

## Apple 官方依据

- [errorNoData](https://developer.apple.com/documentation/healthkit/hkerror/code/errornodata)：无匹配数据时不能计算统计结果。
- [errorDatabaseInaccessible](https://developer.apple.com/documentation/healthkit/hkerror/code/errordatabaseinaccessible)：设备锁定导致健康数据受保护。
- [errorHealthDataRestricted](https://developer.apple.com/documentation/healthkit/hkerror/code/errorhealthdatarestricted)：设备管理策略可限制健康访问。


## 用户后续确认

用户确认使用iPhone真机，安装unsigned产物，Development版本未生成。原push流程固定unsigned，因此不会执行开发签名；现在默认改为Development，参见[IPA构建](IPA_BUILD.md)。需在目标设备包含于描述文件、HealthKit能力齐全的前提下安装签名包重新验证。该反馈缩小了排查范围，但尚未检查设备实际安装签名，不能声称已经确定或修复该设备的全部故障原因。
