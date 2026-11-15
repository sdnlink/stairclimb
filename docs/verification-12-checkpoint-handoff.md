# ios_circles 保存候选交接复核

2026-11-15 本次恢复后，源码基线仍为 `d968fe82642748511164b97cfa91761ffaad6d4a` 加保存的圈子工作区差异，需求版本7。本次仅新增此交接记录；不修改业务实现、测试、历史证据、监督器文件或Git引用，不暂存或提交。

独立评审输入已接受 `ios_network`、`ios_email_auth` 并重新确认七个前置模块；没有新的业务阻断发现。下一未接受模块 `ios_circles` 的实现及聚焦检查已保存在工作区，本次核实后直接提交该模块，不扩展其他模块。模块台账是否登记接受仍由独立reviewer及Watcher决定。

本次实际只读检查均退出0：

| 命令 | 结果 |
| --- | --- |
| `git rev-parse HEAD` | `d968fe82642748511164b97cfa91761ffaad6d4a` |
| `sha256sum -c docs/validation/ios-circles-sources.sha256` | 64/64匹配，包含当前Swift圈子增量、工程、真实HTTPS探针及复用依赖 |
| `sha256sum docs/validation/ios-circles-sources.sha256` | `d65877330eb8c9f59a8c7f84c46012ad8cb39093a2c0e7e8b1bb6995045d73b2` |
| `sha256sum docs/validation/ios-circles-structure.txt docs/validation/ios-circles-focused.txt docs/validation/ios-circles-regression.txt` | 三项摘要与 `docs/verification-12-ios-circles.md` 完全一致 |
| `git diff --quiet HEAD -- backend` | 后端源码、迁移、配置及测试未变 |
| `git diff --check` | 无空白错误 |

已检查圈子页面的实际Tab/邮箱入口、单独主动参与、真实成员分页/定位、撤回与删除接线，以及 `SocialModel` 的频道/版本校验、同步发送前清除旧圈、在途响应及上海跨日隔离。`CircleTests.swift` 的13项测试方法仍关联实际XCTest target；未执行Swift测试。

复用同一候选保存的验证，不重复执行：`python3 scripts/check_ios_project.py` 退出0；`python3 scripts/verify_ios_circles.py` 退出0，使用三名真实验证邮箱用户、Rust/PostgreSQL、正常CA验证HTTPS及隔离SMTP；`python3 -m unittest backend.tests.test_circles scripts.tests.test_ios_project -v` 55项通过、退出0。完整命令、边界和清理结果见 `docs/verification-12-ios-circles.md` 及其三份原日志。本次没有运行构建、测试或服务，没有冒称新一轮Watcher已通过。

为避免依赖登记遗漏，本次结论联合列出已核验前置 `backend_rust_postgres`、`backend_identity`、`backend_social`、`backend_circles`、`backend_email_auth`、`https_transport`、`ios_local`、`ios_network`、`ios_email_auth`。后端历史HTTPS清单22/22输入匹配，保存的103项HTTP及14项Rust回归证据保持原样。当前完整圈子清单64/64匹配；旧邮箱清单48/55匹配，差异恰为本圈子候选的7个修改文件，不能声称旧清单整体仍匹配。成功邮箱HTTPS探针及66项回归日志摘要分别仍为 `dc35e8b25ea080bab05a5f92991f8f629c73a64f67fc10fc8438ff8867758ca5`、`10e691b0597dfbb3b2c6397a683c547e392a39bac7edc63b38586bb0bde66c10`；相关变更已由当前圈子检查覆盖。本地HealthKit/日期/身份实现及严格HTTPS、邮箱存储实现沿用已接受证据，无重写。

仅提交模块完成，不提交整个需求完成。后续仍有 `backend_data_access`、`ios_freshness`、`apple_build_validation`、`delivery_validation`、`circles_delivery`、`email_auth_delivery`；不把它们列为当前圈子模块的缺陷。没有新增模块定义，不改变既有定义或自行关闭AUD编号。

Linux缺少Apple工具链的已知限制未变，未重复探测或尝试替代平台：Swift编译、XCTest执行、系统ATS/URLSession、Keychain、签名、真机HealthKit及视觉交互均未执行；真实Mac命令保留于README。它们仍须在Mac/iPhone执行，不能由Linux结构/后端契约检查替代。最终持续运行实例及PID/日志/停止命令属于最终交付模块，本次未启动或宣称交付。
