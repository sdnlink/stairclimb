# GitHub Actions 打包 IPA

工作流：[Build iOS IPA](../.github/workflows/ipa.yml)。使用 `macos-15` 与runner默认完整Xcode16+，先执行Debug/Release模拟器构建及全部XCTest；通过后执行iPhoneOS Release archive并导出IPA。失败保留日志和结果包，不上传伪成功产物。本流程不向App Store/TestFlight自动提交。

当前版本使用Core Motion本机计步，**不再要求HealthKit描述文件**。运动与健身权限在App运行时由用户授权；Development签名、团队、App ID和目标设备仍需正确配置。

## 使用

代码推送到GitHub后，打开 **Actions → Build iOS IPA → Run workflow**，选择分支和`signing`：

| 模式 | 用途 | 必要配置（优先项 → 备用项） |
| --- | --- | --- |
| `unsigned` | 无签名设备编译包；不能直接安装 | 无证书 |
| `development`（默认） | 描述文件内设备开发测试 | DEV_CERTIFICATE_P12 → BUILD_CERTIFICATE_P12；DEV_P12_PASSWORD → P12_PASSWORD；DEV_PROVISION_PROFILE → BUILD_PROVISION_PROFILE；APPLE_TEAM_ID |
| `ad-hoc` | 描述文件内设备分发测试 | DIST_CERTIFICATE_P12 → BUILD_CERTIFICATE_P12；DIST_P12_PASSWORD → P12_PASSWORD；DIST_PROVISION_PROFILE → BUILD_PROVISION_PROFILE；APPLE_TEAM_ID |
| `app-store` | 后续App Store/TestFlight上传使用的签名包 | 与ad-hoc同名变量，但必须配置App Store类型描述文件 |

`main`分支相关源码push及手动默认构建`development`，使用已有DEV证书配置。需要无签名编译检查时必须手动选择`unsigned`；不会在签名配置缺失时悄悄退回未签名包。每次运行使用独立artifact名称和7天保存期。分支并发运行会取消上一次同分支打包。未配置pull_request触发签名流程。

在仓库 **Settings → Secrets and variables → Actions → Repository secrets** 保存上述证书、密码和描述文件。`APPLE_TEAM_ID`既支持同名Secret，也支持同名Repository variable，Secret优先。P12和描述文件的值必须是文件的**完整base64编码**，不是文件路径、证书文本或仓库中的文件。密码是原始密码文本。不要将真实配置写入源码或讨论日志。

Mac上准备base64，可将下面命令的输出直接粘贴进相应Secret：

```sh
base64 -i distribution.p12 | pbcopy
base64 -i AdHoc.mobileprovision | pbcopy
```

`DIST_*`只能存放一套分发描述文件：选择`app-store`前，应确认其确实为App Store描述文件，Ad Hoc描述文件不能用于App Store导出。流程不会擅自转换描述文件或下载、更新设备列表。Ad Hoc和Development必须事先在Apple Developer注册目标iPhone的UDID，并重新生成包含该设备的描述文件。

App ID必须显式指定（不支持通配符），且团队与证书一致；无需HealthKit能力。流程从描述文件读取Bundle ID用于打包，不写回工程；描述文件过期、Team不符或模式不匹配时直接失败。导出后解包实际IPA，再验证签名、无HealthKit entitlement、团队、App ID及开发调试标志；`receipt.json`的`no_healthkit_entitlement_verified`和`exported_signature_verified`只有这些检查通过才会为true。证书身份与描述文件是否可配对由Xcode实际签名验证，密码错误或证书缺私钥也会失败。

当前没有Widget target，`DEV_WIDGET_PROVISION_PROFILE`和`DIST_WIDGET_PROVISION_PROFILE`不使用。`BUILD_*`作为通用备用配置使用。`APPSTORE_API_KEY_ID`、`APPSTORE_API_PRIVATE_KEY`、`APPSTORE_ISSUER_ID`本流程不读取，因为当前只打包并导出，不自动上传Apple，也不请求自动管理证书。

## 下载产物

运行成功后，在该次Actions页面的 **Artifacts** 中下载`StairClimb-<模式>-<run_id>-<attempt>`。GitHub下载的是外层ZIP，解压后包含：

- `StairClimb-<模式>.ipa`。
- 同名`.ipa.sha256`，用于核对传输完整性。
- `receipt.json`，记录源码Git版本、导出模式、Bundle ID、实际命令退出状态、SHA-256和签名清理状态。

另有`StairClimb-ipa-diagnostics-*`保存Xcode日志、构建收据、`Tests.xcresult`、`Archive.xcresult`。不上传整个`.runtime`、钥匙串、P12、描述文件、邮件或数据库凭证。签名时使用临时钥匙串，结束后删除，并恢复原钥匙串搜索列表及被覆盖的同UUID描述文件。

Development/Ad Hoc IPA只能安装到该描述文件允许的设备；可使用Xcode或Apple Configurator进行自有设备安装。App Store IPA供后续上传分发，不能作为Ad Hoc包直接安装。未签名包不能直接安装。签名导出成功仍不代表已在iPhone安装或验证过Core Motion计步、网络信任和UI。

## 本地Mac命令

```sh
python3 scripts/validate_apple.py --output .runtime/ipa-validation-manual
python3 scripts/build_ipa.py --output .runtime/ipa-unsigned-manual
# 已通过安全途径设置必要签名变量时：
python3 scripts/build_signed_ipa.py --mode ad-hoc --output .runtime/ipa-signed-manual
```

每个输出目录必须不存在，避免混用旧产物。建议只在一次性CI runner运行签名命令；流程会临时安装描述文件并修改当前用户钥匙串搜索列表，正常失败路径会恢复。强制关机/强制杀进程无法保证finally执行，因此不要在长期共用runner留下签名材料。

## 当前验证边界

Linux已通过actionlint v1.7.7工作流检查及打包编排和配置验证测试，覆盖错误团队、过期、无HealthKit的合法配置、通配App ID、错误分发模式、缺Secret、模拟器误打包、签名成功/失败的材料清理与密码不落日志。这些测试用替代Apple命令，仅验证脚本行为，不证明完成Swift编译或真实签名。首轮GitHub Mac运行已完成Debug/Release编译，但真实Keychain测试因关闭模拟器签名返回-34018，未导出IPA。本次改为模拟器ad hoc签名并显示失败详情，仍需新提交的Actions运行确认修复后结果，见[CI修复记录](verification-keychain-ci.md)。

聊天目前按所有者要求关闭，IPA使用现有`CommunityFeatures.chatEnabled = false`。重新开放交流前需完成[UGC前置条件](CIRCLE_COMMUNITY.md)。


## XCTest失败与重跑

`xcodebuild test`退出65可能是断言失败，不代表应用编译失败。入口会直接打印编译错误或失败断言的上下文；若有`Tests.xcresult`，即使测试失败也会尝试提取统计和失败详情。原始日志与结果包仍由always步骤上传。实际Keychain测试保持启用，模拟器通过ad hoc签名运行，不依赖本仓库的DEV/DIST证书。

推送修复提交后，在新提交上运行workflow。直接点旧失败运行的Re-run会继续使用旧源码，无法应用新修复。诊断产物在运行页面底部Artifacts，名称为`StairClimb-ipa-diagnostics-<run_id>-<attempt>`；解压后查看`xctest.log`和`test-summary.log`。


## iPhone 真机计步测试

当前默认Development签名包，使用既有`DEV_CERTIFICATE_P12`、`DEV_P12_PASSWORD`、`DEV_PROVISION_PROFILE`及`APPLE_TEAM_ID`。不需要HealthKit描述文件；当前所选描述文件若只是缺少HealthKit，迁移版不再因此拒绝构建。它仍须为正确Team和显式App ID、包含目标iPhone、未过期并与证书匹配。

推送新代码后，在新提交运行workflow。全部XCTest和导出签名检查通过后，下载`StairClimb-development-<run_id>-<attempt>`中的`StairClimb-development.ipa`，按正常签名方式安装，开启运动与健身权限。具体设备验收见[Core Motion本机计步](MOTION_COUNTING.md)。本次没有读取GitHub Secret值，也没有生成真实IPA；最终结果以新提交的macOS Actions为准。

旧版`Profile must enable the HealthKit capability`门禁已随本项目停止使用HealthKit而移除。只在新源码运行才会采用此更改；旧运行Re-run仍使用旧代码。保留团队、App ID、描述文件类型及最终签名校验，并拒绝最终应用重新带入HealthKit entitlement。新的收据标记`step_source: core-motion`，不代表系统运动权限已被用户授予或真机计步已通过。
