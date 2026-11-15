# 2026-11-15 XCTest Keychain CI失败与修复

## 来自真实Actions的证据

运行：[Build iOS IPA 43700062350](https://github.com/sdnlink/stairclimb/actions/runs/43700062350)，源码`6eebd1777bc3390bf7d90df4d9cc541a10249d72`。诊断产物`StairClimb-ipa-diagnostics-43700062350-1`已由always步骤上传，artifact ID为14156755302，约61MB，包含`xctest.log`、`receipt.json`和`Tests.xcresult`。原始XCTest日志共129601字节，故“没有在步骤控制台看到细节”不等于文件没有生成。

Mac环境为Xcode16.4（16F6），iPhone16 Pro Max模拟器，iOS26.2 runtime。结构检查、Debug/Release应用构建均返回0，XCTest返回65。实际99个测试用例运行，98个通过；`IdentityVaultTests.testActualKeychainInsertUpdateAndRead`同一用例出现两处失败：

```text
IdentityVaultTests.swift:72: error: ... XCTAssertNil failed: threw error "Failure(status: -34018)"
IdentityVaultTests.swift:73: error: ... failed: caught error: "Failure(status: -34018)"
Executed 99 tests, with 2 failures (2 unexpected)
```

该错误对应Keychain缺少entitlement。失败命令显式设置`CODE_SIGNING_ALLOWED=NO`，关闭了宿主应用签名。测试目标已经编译并运行，失败并非Swift编译错误，也尚未进入IPA签名导出阶段。

## 改动

- 完整模拟器构建和XCTest统一使用`CODE_SIGNING_ALLOWED=YES`、`CODE_SIGN_IDENTITY=-`、`AD_HOC_CODE_SIGNING_ALLOWED=YES`，让测试宿主保留ad hoc签名。这种模拟器本地签名不依赖开发者证书、Team或描述文件，与真机Ad Hoc分发模式不同。
- 原生Keychain读写测试保留，继续验证真实Security API，不转成mock、不跳过、不清空既有安全策略。
- 失败命令的编译错误、断言上下文和日志末尾直接输出Actions控制台，最多90行，每行最多1500字符。
- XCTest退出非0且存在结果包时，仍提取统计和失败详情。摘要读取失败不替代原始XCTest退出65；任何失败均阻止IPA导出。
- 无失败、无跳过且非零测试的成功门禁保持；原始日志、收据和结果包仍由既有always步骤上传。

## 本地验证和剩余验证

Linux执行：全部61项脚本测试通过（其中Apple编排18项），iOS工程结构检查通过，`git diff --check`通过。新增回归覆盖模拟器签名参数、失败断言显示、失败结果包提取、结果包不可读时保留原始失败及输出边界。Apple命令使用替代工具，只验证编排，不代表本次修复已完成实际Mac测试。

修复必须推送新提交后在新版本运行workflow。旧运行直接Re-run会重复使用旧提交。新的Mac运行还需要确认：

1. 应用和测试宿主使用模拟器ad hoc签名。
2. 99项XCTest全部通过，包括真实Keychain读写。
3. 通过后进入所选IPA打包模式；真机签名、安装和HealthKit交互仍独立验证。
