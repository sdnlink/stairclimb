# 爬楼梯

原生 SwiftUI iOS 应用 + Rust HTTP/PostgreSQL 后端的分模块实现（按最新技术栈授权迁移）。所有楼层都是每 100 步兑换的虚拟游戏楼层，日界线统一为 **Asia/Shanghai**，不采集真实地理位置。

当前后端已实现服务器规则、身份认证、昵称、带版本锁的共享状态、当日累计快照、真实分页排行榜、本人定位、隐私删除，以及按每日步数自动匹配的运动圈子。SwiftUI 工程含本机 HealthKit 楼梯进度、Keychain 身份及真实 API 联网注册/共享、排行榜、隐私操作和中文“今日运动圈子”页面；没有静态假榜单。Linux检查与真实HTTPS契约验证已执行，Apple平台验证仍未执行，最终集成交付尚未完成。

邮箱认证已接通注册验证、登录、刷新/退出、找回密码与旧身份绑定，见[邮箱API和SMTP运行说明](docs/EMAIL_AUTH.md)。正式匿名注册已关闭，Swift中文邮箱表单已接通注册、验证、登录、重发、找回/重置、旧身份绑定与退出；原生TLS服务与严格HTTPS客户端策略见[HTTPS配置](docs/HTTPS.md)。本轮交审`backend_data_access`：连接池、用户行锁和数据库分页见[访问边界与实验](docs/DATA_ACCESS.md)，保留已接受的圈子、邮箱与联网模块。后续Swift时间标记/Mac构建入口及最终集成交付继续必交，不以本模块交审替代全需求完成。

## 本地启动

需要 Rust/Cargo、Python 3.10+（验证/迁移工具）以及可用 Docker。正式 HTTP 由本项目编译的 Rust 二进制提供，业务数据仅存 PostgreSQL；旧 Python 服务仅保留为历史参考，不参与启动或当前 HTTP 验收。本地验证使用隔离邮件捕获器，无需付费服务或开发者账号；正式邮箱投递须由部署者配置SMTP。

```sh
cd /home/skn/code/stairclimb
python3 scripts/postgres_dev.py start
python3 scripts/dev_tls.py --name stairclimb.local
. ./.runtime/postgres.env
. ./.runtime/tls/server.env
sh scripts/run_backend.sh
```

数据库脚本只管理带本项目标签的 `stairclimb-pg-<路径摘要>` 容器和专用卷，使用 PostgreSQL 17、仅绑定 `127.0.0.1` 的 OS 随机端口。连接凭证随机生成，保存在被忽略且权限600的 `.runtime/postgres-container.env` 与 `.runtime/postgres.env`；不要打印、提交或发送这两个文件。无密钥运行信息见 `.runtime/postgres.json`。停止仅本任务数据库：`python3 scripts/postgres_dev.py stop`，数据卷保留；不会停止或删除无关容器。

启动脚本先执行 `cargo build --locked --manifest-path backend/Cargo.toml --bin stairclimb-server`，再 `exec backend/target/debug/stairclimb-server`。加载上述TLS配置后默认 `https://127.0.0.1:8443`，前台 Ctrl-C 停止。未加载TLS的内部测试HTTP仍默认 `127.0.0.1:8787`。端口可用 `sh scripts/run_backend.sh --port 8788`，或设置 `STAIRCLIMB_HOST` / `STAIRCLIMB_PORT`。`DATABASE_URL` 必须配置。连接串不出现在启动日志中。首次启动以事务及迁移锁应用 [版本化迁移](backend/migrations/001_initial.sql)，空库可直接启动，重启保留数据。

外部自备 PostgreSQL 时可复制 [无密钥配置示例](backend/development.env.example) 到被忽略的 `.env`，填写自己的 `DATABASE_URL` 后 `. ./.env` 再启动；示例所有变量均显式export，`CHANGE_ME`不是可用凭证。当前默认本地连接不使用数据库 TLS；远程数据库须自行配置可信 TLS 通道，本任务不部署公网服务。

数据库连接池默认最多8个连接（含正在创建），获取等待1500ms；可用示例中的`STAIRCLIMB_DB_POOL_MAX`和`STAIRCLIMB_DB_POOL_TIMEOUT_MS`调整。池耗尽返回503 `database_busy`，连接归还后恢复；详细锁顺序、迁移003、分页和真实规模实验见[数据库访问说明](docs/DATA_ACCESS.md)。

```sh
curl --fail --silent --cacert .runtime/tls/ca.pem https://127.0.0.1:8443/health
```

Rust直接提供TLS1.2/1.3：两项证书路径必须同时配置，非法配置启动失败，不降级。无TLS时HTTP仅允许回环，不能用于iPhone。Debug和Release现在都强制HTTPS、默认系统证书信任，无ATS放宽。iPhone的127.0.0.1指手机自身；真机需证书SAN覆盖的Linux局域网地址/域名并安装、信任自己的开发CA。完整生成、证书信任、LAN配置、自备正式证书及停止步骤见[HTTPS说明](docs/HTTPS.md)。

## 验证

固定验收命令（Python HTTP 测试自动准备本任务 PostgreSQL、编译测试专用 Rust 服务；每个测试拥有随机独立 schema 和 OS 分配的 HTTP 端口，结束清理，不接触开发身份）：

```sh
python3 -m unittest discover -s backend/tests -p 'test_*.py' -v
cargo test --locked --manifest-path backend/Cargo.toml --all-targets
cargo fmt --manifest-path backend/Cargo.toml --all -- --check
```

测试以真实 HTTP 验证多用户注册→主动共享→累计同步→全榜分页和本人定位，以及改名、重复同步、并列排序、跨日、非法输入、越权、撤回、删除和服务重建后的持久化。测试也覆盖等待 PostgreSQL 事务行锁期间跨越午夜、并发上传与隐私操作，以及数据变化后拒绝旧分页。接口详见 [API 文档](docs/API.md)。

以下早期 Python/SQLite 日志保留为历史证据，不能证明 Rust/PostgreSQL 已通过。评审修复后的 23 项回归结果与配置启动验证见 [修复记录](docs/verification-01-repair.md)。

累计同步/排行榜/隐私删除的针对性验证可独立复现：

```sh
python3 -m unittest backend.tests.test_social -v
```

本轮新增行为与完整回归的实际输出见 [社交模块验证记录](docs/verification-02.md)。保留的 [身份模块原始记录](docs/verification-01.md) 与修复日志未改写。

排行榜仅展示仍同意共享的账号；当日未同步者显示 0 步/0 层。相同步数同名次，顺序按稳定用户 ID 排列。撤回后立即从后续榜单及圈子移除并拒绝上传，已存记录保留为本人私有；再次主动共享会重新公开仍保留的当日榜单值，但圈子须另行主动同意。**删除全部共享步数**清除所有日期记录，同时关闭共享及圈子参与，阻止旧上传写回；身份保留。此为新增产品要求对先前删除默认的明确加强。**删除账号**则清除身份、昵称、共享状态、圈子参与及关联步数，旧凭证永久失效。服务端无法收回其他用户已经看到或自行保存的数据。

## 每日运动圈子

每天上海00:00，今日统计及频道按新日期重新推导，无需用户打开App或定时清库；历史步数不改写，也不操作 Apple Health 原始数据。集中默认每 **1000步** 一圈：0–999、1000–1999等。频道ID由「日期:区间」构成，同区间同频道；跨区间同步后自动迁圈，不凑人数、不生成假成员。

圈子需要额外主动同意“按步数区间分组，昵称、当日汇总步数及虚拟楼层会对圈友可见”，旧共享账号不会自动加入。未参加仍可本地运动，也可仅共享排行榜。撤回共享、退出圈子、删除共享步数都会停止上传并移除圈子资格；重新共享榜单不会自动重新参加圈子。接口及退出、删除语义见 [API](docs/API.md)。

“运动圈子”标签打开中文“今日运动圈子”页面，展示上海日期、频道、1000步区间、真实人数、昵称、步数、虚拟楼层及本人标记，可加载全部圈友、定位本人、刷新。未登录可直接进入邮箱表单；先在榜单主动共享，再在圈子单独确认参与。小圈直接显示真实成员，不混入其他区间；未参加、加载、错误及退出待确认均有明确状态。圈友请求失败清除旧成员并提示重试；分页版本变化要求从头刷新。同步发送前隐藏旧圈友，避免可能迁圈或丢失上传响应后仍展示旧频道。退出同时撤回共享，待确认时停传且不会自动参加；删除入口仍在榜单的隐私操作中。

新增要求已先经独立 reviewer 确认覆盖，见[评审记录](docs/review-03-amendment.md)。保存的[圈子后端记录](docs/verification-03.md)继续保留；本轮原生圈子及真实HTTPS契约记录见[ios_circles交审](docs/verification-12-ios-circles.md)。复现本轮聚焦及相关回归：

```sh
python3 scripts/check_ios_project.py
python3 scripts/verify_ios_circles.py
python3 -m unittest backend.tests.test_circles scripts.tests.test_ios_project -v
```

探针使用三个实际验证邮箱账号、受信任测试CA、Rust/PostgreSQL及隔离SMTP，核对999/1000分圈、分页本人、双向迁圈、重复同步、隐私删除、重启、上海午夜、历史保留及503，不向外部邮箱发送邮件。端口、schema、证书及邮件在结束后清理；不等于iOS运行验证。Swift圈子测试已关联现有target，可在Mac按下文完整测试命令运行，或聚焦执行（按实际模拟器名称调整）：

```sh
xcodebuild -project ios/StairClimb.xcodeproj -scheme StairClimb -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 16' CODE_SIGNING_ALLOWED=NO -only-testing:StairClimbTests/CircleRuleTests -only-testing:StairClimbTests/CircleStateTests test
```

## iOS 本机进度模块

在 Mac 使用 **Xcode 16+、iOS 17+** 打开 [StairClimb.xcodeproj](ios/StairClimb.xcodeproj)。共享 scheme 为 `StairClimb`，应用 target 为 `StairClimb`，已关联 `StairClimbTests` XCTest target。Swift 源码、资源、配置与 scheme 均直接交付，无需先安装工程生成工具。

主界面为中文可视化楼梯，突出“我”的虚拟楼层，显示今日步数、楼层、距下一层步数以及上海日期/读取时间。无首次读取结果时显示“—”，无可读数据时明确说明可能无记录或没有读取权限；HealthKit 不向 App 透露拒绝读取的可靠状态。查询错误保留并标注同日上次结果，不冒充成功零值。回前台和下拉重新读取；前台上海午夜清空旧日展示并重新查询，异步旧日结果不能覆盖新日。HealthKit 只请求读取 `.stepCount`，按上海00:00至次日00:00查询汇总，无写入或删除健康数据，无演示数据。

点击右上角创建/修改本机昵称。本机 UUID 和昵称完整保存在 Keychain（`WhenUnlockedThisDeviceOnly`，不作云同步），安全存储失败不自动生成替代身份。**本机 UUID 不是后端账号或认证凭证**；现有“今日楼层榜”使用独立Keychain联网凭证；邮箱注册与登录入口不再调用匿名API，正式服务不接受新匿名注册。本机查看无需共享同意，也不需要联网注册。本机昵称身份没有找回机制；联网邮箱账号可登录或重置密码。旧匿名身份绑定前丢失凭证无法保证找回，重装后的 Keychain 保留也不能保证。

Linux 可复现检查（Python 标准库，无需 Swift/Xcode）：

```sh
python3 scripts/check_ios_project.py
python3 -m unittest discover -s scripts/tests -p 'test_*.py' -v
```

检查解析真实 PBX 对象图、源文件和测试 target 关联、共享 scheme、配置包含关系、HealthKit capability/entitlements、中文隐私说明、图标及 Debug/Release ATS；还核对 Rust 权威规则、历史Python规则参考和Swift的换算、上限及1000步参数一致。检查器自身的隔离回归会破坏工程引用、scheme、entitlement、ATS等输入，验证确实拒绝错误配置。这些都是静态结构检查，**不等于 Swift 编译或 XCTest 已运行**。本轮日志和源码指纹见 [ios_local 验证记录](docs/verification-04.md)。

Mac 编译和单元测试命令（仓库根目录执行；先用 `xcrun simctl list devices available` 确认已安装的 iPhone 模拟器，按实际名称替换测试 destination）：

```sh
xcodebuild -project ios/StairClimb.xcodeproj -scheme StairClimb -configuration Debug -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project ios/StairClimb.xcodeproj -scheme StairClimb -configuration Release -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project ios/StairClimb.xcodeproj -scheme StairClimb -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 16' CODE_SIGNING_ALLOWED=NO test
```

Swift 测试覆盖0/99/100/101/最大值、剩余步数、非法汇总、上海午夜/年月/闰日、不同设备日区、昵称、Keychain持久读写、首次请求/无数据/错误、前台更新、并发读取及午夜旧响应隔离。模拟器测试通过也不能证明真机 HealthKit 可读。真机需在 Signing & Capabilities 选择自己的 Team 和唯一 Bundle ID，确认 HealthKit 权限并在 iPhone 中实际授权、走路、拒绝读取、返回前台验证；不需要本项目代注册或购买开发者服务。

## iOS 联网与隐私

“今日楼层榜”→“注册、验证或登录”打开中文邮箱账号表单。选择“邮箱注册”填写邮箱、密码和公开昵称，实际查看邮件后选择“验证邮箱”，输入邮件内43位凭据和注册密码；仅服务器确认`completed:true`才显示验证完成，然后另行登录。提供重发、忘记密码和重置入口；SMTP未配置/失败、凭据过期/已用、限流和认证失败均显示错误，不冒称已投递或已验证。所有连接强制HTTPS和系统证书信任；本机HealthKit继续独立可用。登录不自动开启健康共享或圈子参与，上传仍需单独主动同意。完整[邮箱与本地捕获步骤](docs/EMAIL_AUTH.md)。


“读取今日步数并同步”先刷新共享版本，再读取HealthKit，仅在本次成功读取的上海日期与服务器一致时上传 `date/steps/expected_revision`，不上传原始样本。无可读数据状态的临时0值及失败保留的旧值不上传；真实读取到0则可以上传。成功同意后，回前台与上海午夜会尝试重新读取并同步；没有后台准点任务依赖。超时不重放旧快照，手动重试会重新读取。榜单支持刷新、逐页加载到底和跳到本人所在页；版本变化清除旧页，失败保留的同日结果标明缓存及上海读取时间，旧日榜单立即清除。

撤回、删除全部共享步数和删除账号均有实际入口。确认操作时先停止本机上传并保存待完成意图，等待在途操作结束后提交。服务器成功响应前不会显示完成。待完成操作及其删除版本在Keychain保留；删除超时后如版本已变，必须再次主动确认“删除现存数据”，不会自动采用新版本重放。账号删除后收到401也只显示未确认，不冒称删除成功。重新共享始终要主动确认；刷新、重启和回前台不会重放开启共享或圈子参与。

凭证与服务地址绑定，修改服务前先处理旧账号及数据。“仅移除此机联网凭证”明确不删除或撤回服务器数据，而且没有找回能力；待完成隐私操作时禁止此操作。服务器凭证、资料和隐私意图仅存Keychain，不放入URL、配置或日志；UserDefaults仅保存健康请求流程标记和一个非敏感的“本机停止上传”保险标志。后者在Keychain写失败后也阻止重启自动上传；解锁并重新主动同意后才清除。服务拒绝或认证失效会停传，不自动注册新账号。登录成功而Keychain暂时失败时保留内存中的新会话并允许重试安全保存，不重复登录。刷新在到期前30秒进行，串行轮换access/refresh；结果丢失或重启时发现刷新未确认，停止上传并要求重新登录，不重放旧刷新凭据。401仅对读取最多刷新重试一次，不重放步数或删除请求。

HTTPS/邮箱契约的Linux真实联通验证（自己创建并清理隔离PostgreSQL schema、临时Rust进程、TLS/SMTP端口及私有证书/捕获邮件，不接触开发身份，不打印凭证）：

```sh
python3 scripts/verify_ios_api.py
```

该命令通过受验证CA的HTTPS覆盖3个独立邮箱账号注册/捕获邮件/验证/登录、主动共享、重复同步、三页遍历/非首页本人、改名、跨日、撤回、删除、重启、503、刷新/重放、找回密码后旧会话失效、退出及SMTP失败。验证实际Rust/PostgreSQL契约，不是iOS URLSession运行结果。本轮记录见[iOS邮箱与联网交审](docs/verification-11-ios-email-network.md)，保留[早期联网记录](docs/verification-05.md)及[修复记录](docs/verification-05-repair.md)。Swift新增认证请求、隐私存储、刷新不确定屏障、退出/在途同步、旧身份绑定和重复操作测试源码，已关联实际XCTest target；Mac命令见上文，尚未执行。

“账号设置、登录与找回”仅在本人账号设置中按需读取邮箱，不持久保存邮箱、密码或邮件凭据。表单关闭/切后台清除密码与凭据。退出会先停止本机上传，再等待在途请求并调用`logout-all`撤销全部设备会话；确认前保留待完成状态，重启不会自动上传。退出不撤回共享历史，可先撤回/删除或稍后登录管理。待完成隐私操作必须先完成，不能被退出或更换账号绕过。同账号重登录保留待删除/撤回意图，不同用户登录不会覆盖本机现有身份。

已有匿名Keychain记录兼容保留，通过“绑定旧身份邮箱”发送验证邮件，验证/重置同时使用该设备原凭证。成功后登录原账号，保留原ID、昵称、历史和同意状态；本机停传状态不会被绑定或登录自动打开。若邮箱被他人未验证的旧绑定占用，可申请找回邮件，再主动选择“建立独立账号”；不合并或获取旧身份。切换到另一个账号前须处理原账号数据，再明确移除此机凭证。

当前 Linux 没有 Swift、macOS/Xcode 或 iOS 模拟器；**未进行 Swift 编译、XCTest 执行、签名、真机 HealthKit 或视觉/辅助功能验证**。上述Mac命令不能作为已经通过的证据。Swift成功时间/缓存体验、Mac构建入口、最终集成和持续后端实例仍由后续模块完成，整体需求尚未完成。

监督流程已由外部 Auto Moniter 启动，worker 不修改监督器源码、不提交或暂存 Git。独立 reviewer 和 Watcher 的复核结果由监督流程记录，本 README 不冒称它们已接受实现。


## 旧 SQLite 数据迁移

本轮迁移前只读盘点：默认 `.runtime` 不存在，项目内未发现开发 SQLite 文件，因而没有既有真实开发账号需要自动搬迁。测试和用户自备旧库仍提供有备份的导入路径，不能用空库替代兼容验证。

```sh
python3 scripts/postgres_dev.py start
# 使用新的32位小写随机十六进制schema名；工具仅接受 import_ 或 test_ 前缀。
python3 scripts/import_sqlite.py --sqlite /absolute/path/to/legacy.sqlite3 --schema import_0123456789abcdef0123456789abcdef
```

工具通过 SQLite online backup 创建一致备份到 `.runtime/backups/`（600权限，即使有WAL也不遗漏提交数据），在单个PostgreSQL事务内应用迁移并导入，拒绝非空目标而不清空它。逐字段核对全部用户ID、凭证摘要、昵称、同意版本/开关、圈子参与及各日期累计值/时间戳，并核对分页版本，输出仅有数量、备份路径及摘要。源库保持原样；失败保留备份用于排查，不自动删除源数据。较早仅身份/缺圈子表的库可导入，缺失参与默认为不参加。使用导入schema时在被忽略的连接配置中设置 PostgreSQL `options=-csearch_path=import_<对应32位ID>`，不要改写源码或公开连接凭证。

最新技术栈先行独立复核及模块调整见 [变更确认](docs/review-06-stack-amendment.md)。Rust/PostgreSQL迁移当时的67项HTTP/迁移回归、12项Rust检查、真实Swift契约及源码指纹保留于[迁移验证](docs/verification-06-rust-postgres.md)。原生圈子本轮证据见上文；整体交付和最终持续实例仍未完成。
