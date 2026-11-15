# 本地持续运行交付

需求版本8的正式组合为 **Rust + PostgreSQL + Swift/SwiftUI + 邮箱认证 + HTTPS**，覆盖早期Python/SQLite、匿名注册及开发明文HTTP方案。原模块定义和历史日志保留。本文是 `delivery_validation` 的运行交付入口；圈子扩展及邮箱最终集成交付仍按台账独立复核，整体需求不在本次宣称完成。

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
