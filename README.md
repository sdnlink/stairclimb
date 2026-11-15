# 爬楼梯

原生 SwiftUI iOS 应用 + Rust HTTP/PostgreSQL 后端的分模块实现（按最新技术栈授权迁移）。所有楼层都是每 100 步兑换的虚拟游戏楼层，日界线统一为 **Asia/Shanghai**，不采集真实地理位置。

当前后端已实现服务器规则、身份认证、昵称、带版本锁的共享状态、当日累计快照、真实分页排行榜、本人定位、隐私删除，以及按每日步数自动匹配的运动圈子。SwiftUI 工程含本机 HealthKit 楼梯进度、Keychain 身份及真实 API 联网注册/共享、排行榜与隐私操作。中文圈子页面及最终集成验收仍为后续必交模块；没有静态假榜单。Linux检查与真实HTTP契约验证已执行，Apple平台验证仍未执行。

## 本地启动

需要 Rust/Cargo、Python 3.10+（验证/迁移工具）以及可用 Docker。正式 HTTP 由本项目编译的 Rust 二进制提供，业务数据仅存 PostgreSQL；旧 Python 服务仅保留为历史参考，不参与启动或当前 HTTP 验收。无需邮件、手机验证码、付费服务或开发者账号。

```sh
cd /home/skn/code/stairclimb
python3 scripts/postgres_dev.py start
. ./.runtime/postgres.env
sh scripts/run_backend.sh
```

数据库脚本只管理带本项目标签的 `stairclimb-pg-<路径摘要>` 容器和专用卷，使用 PostgreSQL 17、仅绑定 `127.0.0.1` 的 OS 随机端口。连接凭证随机生成，保存在被忽略且权限600的 `.runtime/postgres-container.env` 与 `.runtime/postgres.env`；不要打印、提交或发送这两个文件。无密钥运行信息见 `.runtime/postgres.json`。停止仅本任务数据库：`python3 scripts/postgres_dev.py stop`，数据卷保留；不会停止或删除无关容器。

启动脚本先执行 `cargo build --locked --manifest-path backend/Cargo.toml --bin stairclimb-server`，再 `exec backend/target/debug/stairclimb-server`。HTTP 默认 `127.0.0.1:8787`，前台 Ctrl-C 停止。端口可用 `sh scripts/run_backend.sh --port 8788`，或设置 `STAIRCLIMB_HOST` / `STAIRCLIMB_PORT`。`DATABASE_URL` 必须配置。连接串不出现在启动日志中。首次启动以事务及迁移锁应用 [版本化迁移](backend/migrations/001_initial.sql)，空库可直接启动，重启保留数据。

外部自备 PostgreSQL 时可复制 [无密钥配置示例](backend/development.env.example) 到被忽略的 `.env`，填写自己的 `DATABASE_URL` 后 `. ./.env` 再启动；示例所有变量均显式export，`CHANGE_ME`不是可用凭证。当前默认本地连接不使用数据库 TLS；远程数据库须自行配置可信 TLS 通道，本任务不部署公网服务。

```sh
curl --fail --silent http://127.0.0.1:8787/health
```

HTTP 仅供本机/可信局域网开发。真机访问 Linux 需显式监听局域网地址（如 `STAIRCLIMB_HOST=0.0.0.0 sh scripts/run_backend.sh`）并使用电脑可达的局域网 IP；**iPhone 的 127.0.0.1 是手机自己**。远程连接必须通过 HTTPS 反向代理，不要直接将此开发 HTTP 服务暴露公网。iOS Release 使用系统默认 HTTPS且客户端拒绝所有HTTP。Debug 配置 `NSAllowsLocalNetworking`，另为 iOS 17+ 的 IP 连接在 `NSExceptionDomains` 中仅允许回环及私有地址 HTTP：`127.0.0.0/8`、`10.0.0.0/8`、`172.16.0.0/12`、`192.168.0.0/16`、`::1`、`fc00::/7`、`fe80::/16`；不含公网或通用 ATS 放行。客户端同时限制为这些地址或本机/`.local`名称。此配置依据 [Apple本地网络ATS说明](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowslocalnetworking) 和 [IP/CIDR例外规则](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsexceptiondomains)，系统实际放行仍需Mac/iPhone验证。

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

新增要求已先经独立 reviewer 确认覆盖及扩展清单，见 [评审记录](docs/review-03-amendment.md)。后端聚焦命令为 `python3 -m unittest backend.tests.test_circles -v`；实现与本轮实际验证见 [圈子后端记录](docs/verification-03.md)。中文圈子页面、Swift分组测试和最终圈子集成仍是必交的后续模块，未用后端里程碑替代整体完成。

## iOS 本机进度模块

在 Mac 使用 **Xcode 16+、iOS 17+** 打开 [StairClimb.xcodeproj](ios/StairClimb.xcodeproj)。共享 scheme 为 `StairClimb`，应用 target 为 `StairClimb`，已关联 `StairClimbTests` XCTest target。Swift 源码、资源、配置与 scheme 均直接交付，无需先安装工程生成工具。

主界面为中文可视化楼梯，突出“我”的虚拟楼层，显示今日步数、楼层、距下一层步数以及上海日期/读取时间。无首次读取结果时显示“—”，无可读数据时明确说明可能无记录或没有读取权限；HealthKit 不向 App 透露拒绝读取的可靠状态。查询错误保留并标注同日上次结果，不冒充成功零值。回前台和下拉重新读取；前台上海午夜清空旧日展示并重新查询，异步旧日结果不能覆盖新日。HealthKit 只请求读取 `.stepCount`，按上海00:00至次日00:00查询汇总，无写入或删除健康数据，无演示数据。

点击右上角创建/修改本机昵称。本机 UUID 和昵称完整保存在 Keychain（`WhenUnlockedThisDeviceOnly`，不作云同步），安全存储失败不自动生成替代身份。**本机 UUID 不是后端账号或认证凭证**；“今日楼层榜”单独创建真实联网账号，服务器凭证也只放入 Keychain。本机查看无需共享同意，也不需要联网注册。没有邮箱/手机号/跨设备找回；退出或丢失凭证无法保证找回，重装后的 Keychain 保留也不能保证。

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

进入“今日楼层榜”，填写服务**根地址**和昵称，点击注册。没有默认公共服务器；本地Debug可填 `http://你的Linux局域网IP:8787`，远程或Release须为HTTPS。地址不允许携带用户密码、路径、查询参数或片段。注册默认不共享，仍可浏览公开榜单；需要上传时点击“了解并同意共享”，主动确认昵称、当日汇总步数和虚拟楼层会公开。已有服务器记录可能在重新同意后再次公开，圈子不会自动加入。

“读取今日步数并同步”先刷新共享版本，再读取HealthKit，仅在本次成功读取的上海日期与服务器一致时上传 `date/steps/expected_revision`，不上传原始样本。无可读数据状态的临时0值及失败保留的旧值不上传；真实读取到0则可以上传。成功同意后，回前台与上海午夜会尝试重新读取并同步；没有后台准点任务依赖。超时不重放旧快照，手动重试会重新读取。榜单支持刷新、逐页加载到底和跳到本人所在页；版本变化清除旧页，失败保留的同日结果标明缓存及上海读取时间，旧日榜单立即清除。

撤回、删除全部共享步数和删除账号均有实际入口。确认操作时先停止本机上传并保存待完成意图，等待在途操作结束后提交。服务器成功响应前不会显示完成。待完成操作及其删除版本在Keychain保留；删除超时后如版本已变，必须再次主动确认“删除现存数据”，不会自动采用新版本重放。账号删除后收到401也只显示未确认，不冒称删除成功。重新共享始终要主动确认；刷新、重启和回前台不会重放开启共享或圈子参与。

凭证与服务地址绑定，修改服务前先处理旧账号及数据。“仅移除此机联网凭证”明确不删除或撤回服务器数据，而且没有找回能力；待完成隐私操作时禁止此操作。服务器凭证、资料和隐私意图仅存Keychain，不放入URL、配置或日志；UserDefaults仅保存健康请求流程标记和一个非敏感的“本机停止上传”保险标志。后者在Keychain写失败后也阻止重启自动上传；解锁并重新主动同意后才清除。服务拒绝或认证失效会停传，不自动注册新账号。注册成功而Keychain暂时失败时保留内存中的凭证并允许重试安全保存，不重复注册。

HTTP契约的Linux真实联通验证（自己创建并清理隔离PostgreSQL schema、临时Rust进程和HTTP端口，不接触开发身份，不打印凭证）：

```sh
python3 scripts/verify_ios_api.py
```

该命令覆盖3个独立身份、主动共享、重复同步、三页遍历/非首页本人、改名、跨日、撤回、删除、重启和503；验证的是实际后端契约，不是iOS URLSession执行结果。新增20个Swift测试方法覆盖请求编码、错误映射、地址策略、身份恢复、健康读取屏障及隐私竞态等；与已有28个一起关联实际测试target。实现边界与原始日志见 [ios_network验证记录](docs/verification-05.md)，AUD-3的本地IP配置修复及当前源码指纹见 [修复记录](docs/verification-05-repair.md)；历史记录不改写。

当前 Linux 没有 Swift、macOS/Xcode 或 iOS 模拟器；**未进行 Swift 编译、XCTest 执行、签名、真机 HealthKit 或视觉/辅助功能验证**。上述Mac命令不能作为已经通过的证据。中文圈子页面、Swift圈子匹配测试、最终集成和持续后端实例仍由后续模块完成，整体需求尚未完成。

监督流程已由外部 Auto Moniter 启动，worker 不修改监督器源码、不提交或暂存 Git。独立 reviewer 和 Watcher 的复核结果由监督流程记录，本 README 不冒称它们已接受实现。


## 旧 SQLite 数据迁移

本轮迁移前只读盘点：默认 `.runtime` 不存在，项目内未发现开发 SQLite 文件，因而没有既有真实开发账号需要自动搬迁。测试和用户自备旧库仍提供有备份的导入路径，不能用空库替代兼容验证。

```sh
python3 scripts/postgres_dev.py start
# 使用新的32位小写随机十六进制schema名；工具仅接受 import_ 或 test_ 前缀。
python3 scripts/import_sqlite.py --sqlite /absolute/path/to/legacy.sqlite3 --schema import_0123456789abcdef0123456789abcdef
```

工具通过 SQLite online backup 创建一致备份到 `.runtime/backups/`（600权限，即使有WAL也不遗漏提交数据），在单个PostgreSQL事务内应用迁移并导入，拒绝非空目标而不清空它。逐字段核对全部用户ID、凭证摘要、昵称、同意版本/开关、圈子参与及各日期累计值/时间戳，并核对分页版本，输出仅有数量、备份路径及摘要。源库保持原样；失败保留备份用于排查，不自动删除源数据。较早仅身份/缺圈子表的库可导入，缺失参与默认为不参加。使用导入schema时在被忽略的连接配置中设置 PostgreSQL `options=-csearch_path=import_<对应32位ID>`，不要改写源码或公开连接凭证。

最新技术栈先行独立复核及模块调整见 [变更确认](docs/review-06-stack-amendment.md)。Rust/PostgreSQL的67项HTTP/迁移回归、12项Rust检查、真实Swift契约及源码指纹见 [本轮验证](docs/verification-06-rust-postgres.md)。后端迁移单独交审，现存 Swift 圈子页面尚待本模块之后验证；整体交付和最终持续实例仍未完成。
