# GitHub Actions 打包 IPA

工作流：[Build iOS IPA](../.github/workflows/ipa.yml)。使用 `macos-15` 与runner默认完整Xcode16+，先执行Debug/Release模拟器构建及全部XCTest；通过后执行iPhoneOS Release archive并导出IPA。失败保留日志和结果包，不上传伪成功产物。本流程不向App Store/TestFlight自动提交。

## 使用

代码推送到GitHub后，打开 **Actions → Build iOS IPA → Run workflow**，选择分支和`signing`：

| 模式 | 用途 | 必要配置（优先项 → 备用项） |
| --- | --- | --- |
| `unsigned` | 无签名设备编译包；不能直接安装 | 无证书 |
| `development` | 描述文件内设备开发测试 | DEV_CERTIFICATE_P12 → BUILD_CERTIFICATE_P12；DEV_P12_PASSWORD → P12_PASSWORD；DEV_PROVISION_PROFILE → BUILD_PROVISION_PROFILE；APPLE_TEAM_ID |
| `ad-hoc`（手动默认） | 描述文件内设备分发测试 | DIST_CERTIFICATE_P12 → BUILD_CERTIFICATE_P12；DIST_P12_PASSWORD → P12_PASSWORD；DIST_PROVISION_PROFILE → BUILD_PROVISION_PROFILE；APPLE_TEAM_ID |
| `app-store` | 后续App Store/TestFlight上传使用的签名包 | 与ad-hoc同名变量，但必须配置App Store类型描述文件 |

`main`分支相关源码push自动构建`unsigned`，无需读取签名密钥；签名模式手动运行。每次运行使用独立artifact名称和7天保存期。分支并发运行会取消上一次同分支打包。未配置pull_request触发签名流程。

在仓库 **Settings → Secrets and variables → Actions → Repository secrets** 保存上述证书、密码和描述文件。`APPLE_TEAM_ID`既支持同名Secret，也支持同名Repository variable，Secret优先。P12和描述文件的值必须是文件的**完整base64编码**，不是文件路径、证书文本或仓库中的文件。密码是原始密码文本。不要将真实配置写入源码或讨论日志。

Mac上准备base64，可将下面命令的输出直接粘贴进相应Secret：

```sh
base64 -i distribution.p12 | pbcopy
base64 -i AdHoc.mobileprovision | pbcopy
```

`DIST_*`只能存放一套分发描述文件：选择`app-store`前，应确认其确实为App Store描述文件，Ad Hoc描述文件不能用于App Store导出。流程不会擅自转换描述文件或下载、更新设备列表。Ad Hoc和Development必须事先在Apple Developer注册目标iPhone的UDID，并重新生成包含该设备的描述文件。

App ID必须显式指定（不支持通配符）、启用HealthKit，且团队与证书一致。流程从描述文件读取Bundle ID用于打包，不写回工程；描述文件过期、Team不符、缺HealthKit或模式不匹配时直接失败。证书身份与描述文件是否可配对由Xcode实际签名验证，密码错误或证书缺私钥也会失败。

当前没有Widget target，`DEV_WIDGET_PROVISION_PROFILE`和`DIST_WIDGET_PROVISION_PROFILE`不使用。`BUILD_*`作为通用备用配置使用。`APPSTORE_API_KEY_ID`、`APPSTORE_API_PRIVATE_KEY`、`APPSTORE_ISSUER_ID`本流程不读取，因为当前只打包并导出，不自动上传Apple，也不请求自动管理证书。

## 下载产物

运行成功后，在该次Actions页面的 **Artifacts** 中下载`StairClimb-<模式>-<run_id>-<attempt>`。GitHub下载的是外层ZIP，解压后包含：

- `StairClimb-<模式>.ipa`。
- 同名`.ipa.sha256`，用于核对传输完整性。
- `receipt.json`，记录源码Git版本、导出模式、Bundle ID、实际命令退出状态、SHA-256和签名清理状态。

另有`StairClimb-ipa-diagnostics-*`保存Xcode日志、构建收据、`Tests.xcresult`、`Archive.xcresult`。不上传整个`.runtime`、钥匙串、P12、描述文件、邮件或数据库凭证。签名时使用临时钥匙串，结束后删除，并恢复原钥匙串搜索列表及被覆盖的同UUID描述文件。

Development/Ad Hoc IPA只能安装到该描述文件允许的设备；可使用Xcode或Apple Configurator进行自有设备安装。App Store IPA供后续上传分发，不能作为Ad Hoc包直接安装。未签名包不能直接安装。签名导出成功仍不代表已在iPhone安装或验证过HealthKit、网络信任和UI。

## 本地Mac命令

```sh
python3 scripts/validate_apple.py --output .runtime/ipa-validation-manual
python3 scripts/build_ipa.py --output .runtime/ipa-unsigned-manual
# 已通过安全途径设置必要签名变量时：
python3 scripts/build_signed_ipa.py --mode ad-hoc --output .runtime/ipa-signed-manual
```

每个输出目录必须不存在，避免混用旧产物。建议只在一次性CI runner运行签名命令；流程会临时安装描述文件并修改当前用户钥匙串搜索列表，正常失败路径会恢复。强制关机/强制杀进程无法保证finally执行，因此不要在长期共用runner留下签名材料。

## 当前验证边界

Linux已通过actionlint v1.7.7工作流检查及打包编排和配置验证测试，覆盖错误团队、过期、缺HealthKit、通配App ID、错误分发模式、缺Secret、模拟器误打包、签名成功/失败的材料清理与密码不落日志。这些测试用替代Apple命令，仅验证脚本行为，不证明完成Swift编译或真实签名。需推送代码并在GitHub手动运行，才能取得真实Mac构建结果和IPA。

聊天目前按所有者要求关闭，IPA使用现有`CommunityFeatures.chatEnabled = false`。重新开放交流前需完成[UGC前置条件](CIRCLE_COMMUNITY.md)。
