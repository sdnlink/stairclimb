# ios_circles 本轮交审

源码基线为 `d968fe82642748511164b97cfa91761ffaad6d4a` 加本轮工作区差异。适用需求版本7，摘要 `0f0b02550ca7868604bdb2b3c4a4bd9d0d0887041c6572f956de80a4d3c87f37`。上一轮独立评审已接受联网、邮箱和七个前置模块，无待修复业务问题。本轮只完成下一项 `ios_circles`，不重写已接受实现或旧模块定义，不宣称全需求完成，也不自行关闭AUD编号。

后发授权继续优先：正式实现仍为Rust/PostgreSQL、Swift/SwiftUI、邮箱验证及全程HTTPS；注册/登录不自动同意共享或圈子参与。`git diff --quiet HEAD -- backend` 退出0，后端实现和测试保持原样；此前验证记录不改写。用户要求的数据库访问优化、Swift成功时间/缓存体验、Mac构建入口以及最终交付继续保留在各自模块，不在本次圈子模块中扩展。

## 实现及边界

- `Views/CircleView.swift`保留真实圈友、日期频道、人数、1000步规则、小圈、分页和定位入口，补上安全存储未就绪、邮箱注册/验证/登录和退出待确认状态。首次参与须单独点击主动同意；本机运动无需参与。退出使用原撤回共享流程；服务器未确认不显示完成，删除步数/账号入口继续复用榜单隐私操作。
- `Network/SocialModel.swift`补强圈子定位的频道、版本、本人及目标页校验；拒绝混合页、重复用户、循环游标、不兼容楼层和错误本人标记。有效参加者至少包含本人，异常空页作为失败清除，不冒称成员加载成功。未参加显示明确状态；错误清除圈友并提示刷新。在途读请求发生撤回、退出或跨日后，旧响应及旧错误不能恢复视图或覆盖新意图。
- `Core/CircleChannel.swift`集中校验规则和成员换算。同步可能迁圈时，在发出累计快照前清除旧成员，即使服务器接受而响应丢失也不会继续显示旧圈。原共享版本、Keychain停传屏障和禁止自动重放开启意图保留。
- 前台、手动刷新和上海午夜复用已有AppShell→foreground→新日HealthKit读取→当日同步→圈子读取路径。昨日频道立即失效；分圈仍由服务器权威计算，不依赖客户端定时写零。
- `CircleTests.swift`从原3项扩至13项方法，保留边界/日区断言并增加最大合法值、多页/非首页本人、分页版本、无效成员/定位、循环游标、在途撤回、离线删除重启、重复参加、午夜旧响应及HealthKit重读、跨区间同步前失效。全部仍关联原XCTest target；这些Swift测试本轮未执行。
- `scripts/check_ios_project.py`扩展检查实际圈子Tab、API、表单、同意/撤回、前台午夜及测试关联；隔离回归新增4项破坏接线/测试输入的检查。静态检查不执行Swift行为。
- 新增 `scripts/verify_ios_circles.py`，使用三个实际验证邮箱身份、隔离邮件捕获、正常CA验证的HTTPS、真实Rust进程及PostgreSQL。端口临时分配，测试使用随机schema，不接触开发身份、不向外部投递邮件。README更新实际入口、复现命令及Mac聚焦测试命令。

## 实际执行

| 命令 | 结果 | 记录 |
| --- | --- | --- |
| `python3 scripts/check_ios_project.py` | 退出0；18应用源码、7测试源码、真实target/scheme、HealthKit、严格HTTPS和圈子接线通过 | `docs/validation/ios-circles-structure.txt` |
| `python3 scripts/verify_ios_circles.py` | 退出0；3用户真实TLS/邮箱/数据库圈子契约通过 | `docs/validation/ios-circles-focused.txt` |
| `python3 -m unittest backend.tests.test_circles scripts.tests.test_ios_project -v` | 退出0；55项，28.446秒，OK | `docs/validation/ios-circles-regression.txt` |
| `git diff --quiet HEAD -- backend`、`git diff --check` | 均退出0；后端无改动、无空白错误 | 本轮最终差异核对 |

聚焦探针覆盖共享不自动参与、同精确步数、999/1000分离、真实小圈、公开字段无邮箱/认证信息、全部分页和非首页本人、双向迁圈、重复快照、旧游标拒绝、撤回版本屏障、重新共享不自动参加、步数删除关闭共享及参与、账号删除、其他成员保留和重启持久化。上海午夜无需写入即可清零重配，拒绝昨日游标/上传并直接核对历史1000步记录未改变；无今日记录为0，真实数据库故障返回503后恢复。所有测试资源退出后清理。

本轮仅运行上述聚焦检查和一次相关回归。三个Watcher固定命令原样保留，由Watcher对本候选执行；本记录不冒称固定全量检查或独立评审已通过。

64项当前源码/配置/夹具指纹见 `docs/validation/ios-circles-sources.sha256`（包含本轮变化及复用依赖，旧清单原样保留）。各证据SHA-256：

| 文件 | SHA-256 |
| --- | --- |
| `ios-circles-sources.sha256` | `d65877330eb8c9f59a8c7f84c46012ad8cb39093a2c0e7e8b1bb6995045d73b2` |
| `ios-circles-structure.txt` | `5ddef44c4e6dbfa338f449b9fa98108ba5f454bd067ab22a3a60a8a1c2f0d512` |
| `ios-circles-focused.txt` | `52c1cf9bf1823af722d75b8f686fa1a33ffd183d1c6c011eb996aa254974857e` |
| `ios-circles-regression.txt` | `0186ea1990bf8f0cd6663d61f73160f751df6426a6f166e46ca95be8332ed52a` |

Linux工具链限制未变，未重复尝试不可用构建。Swift编译、XCTest执行、URLSession/ATS系统信任、Keychain、签名、真机HealthKit和视觉交互均未执行。README给出真实工程/scheme/target的Mac命令，不能把这些源码或命令当作Apple平台已验证结果；本轮Linux和真实HTTPS证据也不能替代它们。

本次提交范围仅为 `ios_circles`。`backend_data_access`、`ios_freshness`、`apple_build_validation`、`delivery_validation`、`circles_delivery`、`email_auth_delivery`仍待后续完成；最终持续Rust/PostgreSQL/HTTPS实例、健康/排行/圈子实请求及PID/日志/停止方式属于最终交付，本轮测试实例均已关闭。未修改Auto Moniter源码、运行状态、历史或Git引用，未暂存/提交、未公网部署或注册外部服务。
