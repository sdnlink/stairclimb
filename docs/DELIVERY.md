# 本地持续运行交付

需求版本8的正式组合为 **Rust + PostgreSQL + Swift/SwiftUI + 邮箱认证 + HTTPS**，覆盖早期Python/SQLite、匿名注册及开发明文HTTP方案。全部16个模块已获独立评审接受，当前完成源码与Linux可运行部分的最终交接，提交整体验收。原模块定义、实现及历史日志保留；下文各模块段落的源码基线和测试数量为当时记录。

## 当前交接

| 交付项 | 入口或实际结果 |
| --- | --- |
| 原生工程 | [StairClimb.xcodeproj](../ios/StairClimb.xcodeproj)，共享scheme `StairClimb`，测试target `StairClimbTests` |
| API及配置 | [业务API](API.md)、[邮箱与SMTP](EMAIL_AUTH.md)、[HTTPS与设备信任](HTTPS.md)、[无密钥配置示例](../backend/development.env.example) |
| 完整集成 | [三用户HTTPS契约日志](validation/email-delivery-integration.txt)覆盖注册验证、分页本人、午夜、撤回删除、重启、503及SMTP失败，退出0 |
| 固定检查 | 第35轮Watcher：Python 124项、Rust 18项、格式检查均退出0；未变实现复用该轮证据，不冒称本次重新运行 |
| 最近邮箱自检 | 2026-11-15 08:02:44 UTC，持续实例认证生命周期及真实排行榜/本人/圈友通过，删除2个自检账号；`.runtime/delivery/email-probe.json` |
| 宿主实时核验 | 2026-11-15 08:09:50 UTC，`python3 scripts/local_service.py status`及下方可信CA健康GET均退出0；HTTPS地址、进程及数据库沿用下文记录 |
| 运行文件 | `.runtime/delivery/service.json`、`final-handoff.json`；日志为同目录`server.log`、`smtp.log`、`build.log`；CA为`tls/ca.pem`，服务证书及私钥保留在该私有目录 |
| Apple验证 | Swift编译、XCTest、签名、系统证书信任、真机HealthKit及视觉交互未执行；[Mac入口与iPhone步骤](APPLE_VALIDATION.md)已交付 |

此次交接基线为 `ea6efdc570b68230d286bcdfe3712498217fd050` 加README和本页状态更新，应用、后端、迁移及测试未修改。宿主核验确认Rust PID1521357、SMTP PID1521354仍匹配启动标识，运行中与磁盘二进制SHA-256均为 `dd563bfa4b1f5761cd6a547d49c685ca58796eda06f215ec25684fe0f7141a91`，15项后端输入摘要全部匹配，迁移为1至3；六张关联业务表当前均为0行，自检未留下假榜单。结构化核验收据保存在权限600的 `.runtime/delivery/final-handoff.json`，不含密码、邮件证明或会话。

这些实时结果来自worker可见的宿主。reviewer的隔离进程/网络视图可能无法观察宿主PID或访问其回环地址，不能把该隔离结果当作服务故障，也不能把worker收据冒称独立实时验证。Apple未执行项按原需求保留为平台限制，不是源码与Linux交付的未实现功能；没有伪造平台结果，也没有为绕过限制放宽HTTPS或改变监听范围。

## 启动、检查与停止

在Linux仓库根目录执行，需要Docker、Rust/Cargo、Python 3.10+、OpenSSL及支持pidfd的Linux内核。本入口支持x86_64/aarch64；Python未暴露pidfd时使用同一内核接口，启动前先验证安全停止能力。Mac构建使用[Apple入口](APPLE_VALIDATION.md)，不使用这个Linux进程管理入口。

```sh
python3 scripts/local_service.py start
python3 scripts/local_service.py status
python3 scripts/local_service.py check
```

`start` 复用本任务带标签的PostgreSQL容器，保留数据；以正式入口编译并运行 `backend/target/debug/stairclimb-server`，不启用匿名测试入口或注入测试时钟。默认尝试 **127.0.0.1:8787，HTTPS**，被占用则让OS分配空闲端口，不停止占用者。另启仅回环的本地邮件捕获进程，使用OS分配端口；该捕获器没有向外部邮箱投递的能力。此入口清除继承的SMTP/服务配置并使用本任务数据库和证书，避免误连外部SMTP或数据库。生产SMTP另见[认证配置](EMAIL_AUTH.md)。

命令返回后Rust及邮件捕获继续运行，日志不依赖当前终端。重复 `start` 复用已经记录且身份匹配的进程；源码或配置更新后需先 `stop` 再 `start`。没有开机自启或崩溃自动重启；`status` 在进程退出或身份变化时失败，不显示虚假运行状态。启动失败会清理本次创建的子进程，保留数据库及私人诊断日志。

运行元数据在被忽略的 `.runtime/delivery/service.json`：包含实际地址、端口、Rust/SMTP PID和进程启动标识、二进制SHA-256、后端源码摘要、源码基线、数据库容器/端口/schema、实际迁移版本、CA/证书路径及日志位置，不含数据库口令或会话。日志为 `.runtime/delivery/server.log`、`smtp.log`、`build.log`；文件权限600，目录700。邮箱捕获文件位于 `.runtime/delivery/mail/*.eml`，属于私有数据，不能提交或复制到验证日志。

2026-11-15本次实际启动：`https://127.0.0.1:8787`，Rust PID `1521357`，SMTP PID `1521354`；数据库容器 `stairclimb-pg-fe5e36b647`，`127.0.0.1:32807`，数据库 `stairclimb` / schema `public`，实际迁移为1、2、3。启动、自检、状态及独立curl健康请求均退出0，原始非敏感响应见 `docs/validation/delivery-running.txt`。源码基线 `ef0ecad6bcba71f6b677d12bafd8c48a42bd3af1` 加本轮交付增量；后端业务源码未修改。重启后PID及空闲端口可能变化，始终以当前 `status` 为准。

`check` 在**该持续运行的正式Rust进程**上执行可信CA验证的HTTPS请求：健康、两个独立邮箱账号注册→读取本地捕获证明→验证→登录、未同意上传被拒、主动共享、101/999累计快照及重复同步、每页1人的完整遍历、本人定位及实际圈子未参加响应。账号昵称明确标为“交付自检”；步数是本任务合成测试数据，不来自HealthKit。两个临时账号在finally中经认证API删除，并验证旧凭证失效，不留下假榜单。结果保存为 `.runtime/delivery/probe.json`，不含邮箱、密码、邮件凭据、access或refresh。错误返回非零，不产生新的通过结果；删除失败明确报错。自检会暂时改变公开分页版本，应在本地开发验收时执行。

只停止本入口记录且身份仍匹配的Rust/SMTP进程：

```sh
python3 scripts/local_service.py stop
```

停止采用pidfd并验证PID、启动时间及命令，拒绝对身份变化的进程发送信号；先检查全部记录，再停止本任务进程。数据库和日志保留。需停止本任务PostgreSQL时，先停止服务，再执行：

```sh
python3 scripts/postgres_dev.py stop
```

此命令只管理 `stairclimb-pg-fe5e36b647`（名称按项目路径摘要生成）及本项目数据卷，不删除数据，不影响无关容器。下次启动保留用户及历史。开发证书和捕获邮件也保留；设备信任不会因停止服务而自动撤销。

## 圈子扩展自检

```sh
# 在持续运行的正式Rust实例上验证真实圈友；需要先start
python3 scripts/local_service.py check-circles
# 隔离schema、测试时钟和临时端口，验证午夜、历史保存、重启及数据库故障
python3 scripts/verify_ios_circles.py
# 新增交付探针回归：真实正式Rust入口、PostgreSQL、HTTPS及隔离邮件
python3 -m unittest backend.tests.test_circle_delivery -v
```

`check-circles` 单独创建三个明确标为“圈子交付自检”的邮箱账号，经本地捕获邮件验证和登录后分别主动共享、主动参加。使用合成的101/999/999步验证同精确步数必定同圈、每页1人的全部遍历及非首页本人定位；重复累计值不改变频道快照。101→1000→101步验证双向迁圈、旧圈移除和旧游标拒绝。随后验证退出同时停传、延迟参加/上传被拒、重新共享不自动参加、步数删除关闭共享和参与、账号删除及其他圈友保留。它只修改自检账号，不给已有用户写入步数、同意或昵称。并发公开数据变化或执行中跨日会如实失败，不重放旧日上传。

结果保存在权限600的 `.runtime/delivery/circle-probe.json`，包含健康、真实排行榜、圈友页面、本人、迁圈及隐私响应，以及运行中Rust PID/二进制摘要和探针源码摘要；不含邮箱、密码或会话。所有已创建账号在finally中尝试删除，核对旧凭证401，并记录实际删除数量；失败返回非零，旧成功收据先移除，清理失败明确标为 `failed_cleanup`。本地捕获邮件仍是私有运行文件。自检会短暂改变公开分页版本，不应与其他验收操作同时运行。

每天以Asia/Shanghai 00:00派生当日零值和新频道，1000步一个区间，同组即同日频道；历史记录保留，不改写为0，不清除Apple Health原始记录。旧日上传及游标被拒；小圈展示真实成员，不虚构圈友。接口、同意与退出/删除规则继续遵循[API文档](API.md#每日圈子与参与隐私)。午夜和503场景只在隔离测试实例上验证，不修改持续实例的时钟或数据库结构。

本轮源码基线为 `ffeb0fadfe80c609adce6682f55dac10daf28124` 加圈子交付增量；后端Rust、数据库迁移及iOS源码保持原样。聚焦测试和真实HTTPS圈子探针日志见 `docs/validation/circles-delivery-focused.txt`，一次相关回归及Linux工程检查见 `circles-delivery-regression.txt`，持续实例实际请求和停止方式见 `circles-delivery-running.txt`。旧 `delivery-*` 和原生圈子证据原样保留；三个固定命令仍由Watcher对本候选运行，不冒称本轮已独立接受。

## 邮箱与HTTPS最终集成自检

```sh
python3 scripts/local_service.py check-email-auth
python3 -m unittest backend.tests.test_email_delivery -v
```

`check-email-auth` 在同一持续运行的**正式Rust HTTPS实例**上创建两个明确标为“邮箱交付自检”的临时账号，只向本地捕获器发信。实际读取捕获证明，验证重发使旧证明失效、未验证不能登录、一次验证不能重放；登录后检查邮箱仅本人账号接口可见，且没有默认共享或参加圈子。然后分别主动同意、同步101/999步，真实请求健康、排行榜、本人及圈友，并对公开成员字段作允许清单检查。

随后撤回第一个账号的共享，验证刷新轮换使旧access/refresh失效、捕获找回邮件并重置密码、旧会话与重置证明不能重放、新密码登录没有恢复共享或参加、退出使当前会话失效及重新登录可用；第二个账号的身份及会话保持有效。最终删除两账号并核对access/refresh失效，不留下假榜单。探针不重启持续服务、不调整其时钟、不改已有账号。执行中跨日、并发榜单变更及服务器限流会如实失败；不要连续高频运行或与其他自检同时执行。限流、过期和故障用隔离实例测试，不在持续实例上绕过限流或人为断库。

结果位于权限600的 `.runtime/delivery/email-probe.json`，含健康/排行榜/真实圈友响应、已完成阶段、实际删除数、当前源码基线、探针SHA-256、Rust PID/二进制摘要及原后端构建版本。旧收据在重跑前移除；错误保留 `failed`，清理未完成标为 `failed_cleanup`，命令返回非零。密码、邮件证明及全部会话仅保存在探针内存中，不进入收据或日志。重发和找回使用最新捕获文件；密码重置发送前同时保留新旧密码候选，发生响应丢失时先确认现有会话，必要时重新登录以删除测试账号。SMTP或数据库仍不可用时只能记录清理失败，不冒称已删除。

本轮基线为 `14c8aaad544865745ddcf896dd9fc0177584c8b0` 加邮箱交付增量，后端业务、迁移、iOS及既有测试保持不变。聚焦4项真实Rust/PostgreSQL/HTTPS/SMTP回归通过，覆盖既有数据保留、全部邮件证明不泄露、重发/重置响应丢失后清理，以及删除失败不能报告成功。真实持续实例自检退出0、删除2个账号，证据为 `docs/validation/email-delivery-focused.txt` 和 `email-delivery-running.txt`。实例沿用Rust PID1521357、SMTP PID1521354、HTTPS 8787及PostgreSQL端口32807；15项后端输入摘要及运行中可执行文件实际匹配，未为报告更新而重启已验证服务。停止方法和证书路径仍见上文。

邮箱交付的集成覆盖由当前检查和未变的历史证据共同支持：

| 验收范围 | 实际入口及证据 |
| --- | --- |
| 邮箱生命周期、SMTP失败、过期、重放、限流和枚举保护、Argon2id、旧身份绑定、账号/会话清理 | `backend/tests/test_email_auth.py`；本轮相关回归 `docs/validation/email-delivery-regression.txt` |
| 可信HTTPS成功，错误CA/域名/过期证书、明文及降级拒绝，公开模型隐私 | `backend/tests/test_https.py`；同一相关回归 |
| 原数据导入、非空目标保护、重启保留凭证/同意/历史，既有运行及圈子探针不变 | `backend/tests/test_migration.py`、`test_delivery.py`、`test_circle_delivery.py`；同一相关回归 |
| 三个邮箱用户真实HTTPS、完整分页/本人、上海午夜、共享屏障、删除、重启、503、SMTP失败 | `python3 scripts/verify_ios_api.py`；`docs/validation/email-delivery-integration.txt` |
| 连接池/数据库分页、Swift成功时间与缓存、HealthKit/Keychain及Mac执行入口 | `pool-timing-sources.sha256`、`ios-freshness-sources.sha256`、`apple-entry-sources.sha256` 中分别31/75/6项未变输入匹配，仅README按本模块更新；现有实验与平台限制继续有效 |
| 实际工程关联、中文隐私、严格HTTPS和Apple入口编排 | `python3 scripts/check_ios_project.py` 退出0；`scripts.tests.test_ios_project` 与 `scripts.tests.test_apple_validation` 纳入本轮同一相关回归 |

一次相关回归命令为 `python3 -m unittest backend.tests.test_email_auth backend.tests.test_https backend.tests.test_migration backend.tests.test_delivery backend.tests.test_circle_delivery scripts.tests.test_ios_project scripts.tests.test_apple_validation -v`：102项通过，193.174秒，退出0。三用户HTTPS契约检查同样退出0。聚焦4项通过后没有重复全仓固定发现；现有Mac入口编排测试在Linux使用替身工具，不能证明Swift或XCTest已经运行。

三个固定命令原样保留，由Watcher对候选执行；第34轮已接受的120项Python、18项Rust及格式检查记录保持原样。本轮不重复整套固定发现，也不冒称Watcher已接受本增量。Swift编译、XCTest、签名、系统信任、真机HealthKit及视觉交互仍需Mac/iPhone；这是既有平台限制，不由Linux测试替代。不向真实第三方邮箱发信、不修改监督器、不部署公网、不购买服务。

## 连接与证书

本实例仅监听Linux回环地址，不对公网部署。健康探针正常验证 `.runtime/delivery/tls/ca.pem`，不使用 `-k` 或关闭验证。实际端口以 `service.json` 为准；默认8787可用时：

```sh
curl --fail --silent --cacert .runtime/delivery/tls/ca.pem https://127.0.0.1:8787/health
```

该CA尚未安装到任何设备。iPhone上的127.0.0.1指手机自身，不能直连此回环实例。真机使用同局域网可达的Linux地址或域名，须生成包含该地址的SAN证书，安装并信任公开CA，再按[HTTPS局域网步骤](HTTPS.md)启动另一受TLS保护的监听。不要向设备发送CA私钥或服务私钥。系统信任、ATS及真机连接仍需Mac/iPhone验证。

## 可复现验证与边界

```sh
# 新增生命周期、真实SMTP/HTTPS/生产入口，以及未变的数据访问优化聚焦检查
python3 -m unittest backend.tests.test_delivery backend.tests.test_data_access -v
# 真实HTTPS多用户API及跨日/撤回/删除/重启/找回密码契约；隔离schema和端口
python3 scripts/verify_ios_api.py
# 实际工程引用、配置、隐私、HealthKit与严格HTTPS检查
python3 scripts/check_ios_project.py
```

原三个固定验收命令保持不变，由Watcher对候选实际执行；最近已接受候选的112项Python、18项Rust及格式成功证据继续有效，本轮新增检查不冒充Watcher接受。新生命周期测试使用独立临时PostgreSQL schema、TLS/SMTP目录及临时端口，覆盖正常流程、端口占用、重启持久化、PID变化拒绝停止、启动失败清理、自检失败不报成功；结束清理自身资源。既有连接池/用户行锁/数据库分页及1万用户对照实验保留，详见[数据访问说明](DATA_ACCESS.md)。

本次聚焦11项通过（6项新增交付、5项既有数据访问），随后只运行一次相关回归：`python3 -m unittest backend.tests.test_identity backend.tests.test_social backend.tests.test_launcher scripts.tests.test_ios_project scripts.tests.test_apple_validation -v`，94项通过，退出0。真实三用户HTTPS契约入口及工程结构检查也退出0。数据访问原32项指纹中31项未变输入全部匹配，唯一变化是本次扩展的README；无需重新实现或重复1万用户实验。必要后端和iOS前置模块沿用未变证据、联合核验，`backend_data_access` 本次按历史接受后的待重新验证状态共同提交。

当前交付证据见 `docs/validation/delivery-focused-final.txt`、`delivery-regression.txt`、`delivery-integration.txt`、`delivery-structure.txt`、`delivery-running.txt`。首轮停止接口因Python缺少pidfd封装失败，原失败保存在 `delivery-focused.txt`；已接通经本机内核实际验证的pidfd接口，并清理那轮所有专属测试进程。没有用失败记录冒充通过。

Swift编译、XCTest、签名、系统证书信任、真机HealthKit和视觉/辅助功能交互仍未执行；Linux源码/结构检查和真实HTTP契约验证不能替代这些结果。完整工程、Mac命令、自动入口及真机验收步骤见[Apple验证说明](APPLE_VALIDATION.md)。独立reviewer和Watcher由外部监督流程运行，本入口不修改它们的源码、运行状态或审计记录，也不代替其接受结论。
