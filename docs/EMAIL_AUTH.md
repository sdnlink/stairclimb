# 邮箱认证 API 与本地邮件验证

当前正式后端为Rust/PostgreSQL，迁移002只新增认证表，保留原用户、凭证摘要、同意版本、历史步数及圈子状态。新账号默认不共享、不参加圈子，邮箱验证及登录不改变这两个选择。公开个人资料、排行榜、圈友仍只有昵称、公开标识和运动汇总；邮箱只在本人账号设置接口返回。

## 请求与生命周期

以下接口共用4096字节请求上限、严格JSON/未知字段拒绝及`Cache-Control: no-store`。凭据只放JSON或Authorization，禁止URL查询。正常响应附共同上海日界线。`POST`方法如下：

| `/v1/auth/` 路径 | JSON字段 | 成功行为 |
| --- | --- | --- |
| `register` | `email,password,nickname` | 202；提交一次性验证邮件，不返回用户或会话 |
| `resend` | `email` | 202；适用的未验证账号取得新凭据，旧凭据失效 |
| `verify` | `token,password` | 200 `{completed:true}`；邮箱归属验证，必须同时知道注册密码；不自动登录 |
| `login` | `email,password` | 200 `{user,token,refresh_token,expires_in:900,...日界线}` |
| `refresh` | `refresh_token` | 同登录；原access/refresh立即失效，不能重放 |
| `logout` | 空对象 | Bearer认证；撤销本次会话及其刷新凭据 |
| `logout-all` | 空对象 | Bearer认证；撤销此账号全部设备会话 |
| `forgot-password` | `email` | 202；提交一次性重置邮件 |
| `reset-password` | `token,password`（新密码） | 200 `{completed:true}`；重置、验证邮箱归属，撤销全部会话及待用邮件凭据；不自动登录 |
| `bind` | `email,password` | 原匿名Bearer认证；202；给现有身份建立待验证邮箱，不新建或合并用户 |
| `register-independent` | `token,password,nickname` | 200 `{completed:true}`；邮箱主人凭找回邮件的有效reset凭据，解除尚未验证的旧身份邮箱关联并创建全新账号；不取得旧身份、不自动登录 |

`GET /v1/auth/account` 仅接受有效邮箱账号access Bearer，返回本人`email,verified:true`及日界线。其他运动接口使用access Bearer，字段/隐私版本契约保持不变。账号删除级联清除邮箱、密码哈希、邮件凭据和会话；健康共享记录删除保留邮箱身份，同时按既有规则关闭共享及圈子。退出仅撤销会话，**不撤回已共享数据**；退出前可先撤回或删除，退出后也可登录管理。

邮箱去首尾空白，限ASCII、最多254字节，本地部分最多64字节；整体按小写唯一，不删除`+tag`或点，不采用邮箱供应商特定归并。密码为12至128个字符，不含控制字符，不修剪、不做组合规则；使用Argon2id v19，m=19456KiB、t=2、p=1，随机16字节盐，存PHC参数字符串。昵称仍是1至24个可见Unicode码点，不从邮箱生成。

access与refresh均为随机32字节base64url（43字符），数据库仅存SHA-256摘要。access有效15分钟；refresh有效30天，每次轮换重新起算。退出可使用access已过期但refresh尚未过期的当前会话执行撤销；完全过期需重新登录。密码重置和删除后旧会话不能恢复。写请求取得现有PostgreSQL事务屏障后检查会话及当前时钟；等待期间被撤销的会话不能写入。只读请求在已取得的数据库快照中读取，已经返回给他人的数据无法收回。

验证/重置凭据同为随机32字节、15分钟、一次性、仅存摘要；重发使同用途旧凭据失效。过期、已用或伪造统一`400 invalid_credential`。验证还需原注册密码，避免邮箱被他人预先注册后误激活；真正邮箱主人可通过找回密码重设未验证新账号并完成邮箱验证。未验证旧身份绑定的验证或重置**另需原匿名Bearer**，不能仅凭邮箱占有既有身份。已验证邮箱身份以后可凭邮箱重置密码，不再依赖旧设备。

若邮箱被他人的旧设备发起了尚未验证的绑定，邮箱主人不需要也不能取得该设备身份。先调用`forgot-password`并实际读取邮件，再主动选择`register-independent`，提交邮件中的reset凭据、新密码和新昵称，即可原子建立**独立账号**。该入口只接受尚未验证的`legacy_binding`目标；不允许解除已验证邮箱或普通注册账号，不接受`user_id`或指定其他邮箱。邮箱归属由这次有效邮件证明，故新独立账号为已验证状态，但仍需另行登录，且默认不共享、不参加圈子。所有旧绑定/找回凭据同时失效，不可重放。

解除只移除旧身份尚未验证的邮箱关联，**保留旧用户ID、昵称、原凭证摘要、所有日期步数、共享版本和圈子状态**，不复制给新账号。旧设备仍可凭原凭证管理自身隐私、另绑自己的邮箱；不能凭旧绑定邮件或旧密码取得新账号。取消关联与新建账号在同一写事务内完成，避免释放邮箱后又被抢先占用。此恢复路径不依赖原绑定期限：旧凭据过期后可重新申请15分钟reset凭据，重启也保留同样规则。它不放宽原`verify`/`reset-password`访问旧身份所需的双重证明。

注册/重发/找回均返回相同202结构，重复账号不覆盖原密码或昵称。每个合法请求都向输入地址提交一封邮件；不适用的请求包含无效占位凭据，不能用HTTP响应或SMTP失败判断邮箱是否已注册。未知、未验证或密码错误登录统一`401 authentication_failed`；未知邮箱执行相同Argon2验证成本。SMTP成功表示上游接受邮件，**不保证收件，也不表示验证完成**；只有验证/重置API实际成功才可显示完成。

每项认证动作同时按真实TCP来源和规范化邮箱/凭据限流：5分钟内来源最多30次，同邮箱/凭据最多5次，超限`429 rate_limited`。计数单独事务提交，认证或SMTP失败不回滚，重启保留；过窗可重试。来源不信任客户端转发头。本机HTTPS代理将导致所有客户端共用代理来源限额，这是保守限制，后续可配置可信代理而不能任意信任X-Forwarded-For。限流表只存带动作的键摘要，清理超过一天的旧窗口；不存原始邮箱或IP。

## 旧身份与迁移

正式`POST /v1/users`返回`403 email_registration_required`。匿名凭证不能看榜单、圈友、开启共享、改名或上传；仍可GET本人以取得当前版本、关闭共享/圈子、删除记录或账号，以及发起邮箱绑定。绑定不接受user_id、不替换其他绑定、不合并重复邮箱账号。完成验证后旧匿名凭证失效，使用邮箱登录取得新会话，原ID、昵称、共享选择和历史保持不变；绑定本身不会重新开启已撤回的共享。

只有测试专用二进制保留历史匿名场景夹具；邮箱测试显式关闭此夹具。正式二进制无启用开关，即便构建时带test-support特性也不能启用旧入口。历史67项测试继续覆盖原行为，不以其替代正式邮箱路径测试。

## 本地捕获与SMTP配置

检测发现本机25端口已有服务，本项目不使用、不修改它。Python无已装SMTP测试包，交付标准库回环捕获器，**没有向外部服务器投递的能力**：

```sh
python3 scripts/smtp_capture.py --port 1025
# 另一终端；先按README启动本任务PostgreSQL
. ./.runtime/postgres.env
. ./backend/email.env.example
sh scripts/run_backend.sh
```

捕获器只监听127.0.0.1，邮件放被忽略的`.runtime/mail-capture/*.eml`（目录700、文件600）。在本机读取邮件并将一次性凭据输入验证/重置请求；不要将完整邮件或凭据打印进共享日志。Ctrl-C分别停止捕获器和服务，数据库用`python3 scripts/postgres_dev.py stop`。停止不自动删除私人捕获文件；可由设备持有人清理该目录。程序不配置生产SMTP时，注册、重发、找回返回`503 mail_unavailable`，不会伪造发送成功；发送失败回滚此次账号/新邮件凭据变更，已有旧凭据继续有效，限流后可重试。

生产示例见`backend/email.env.example`注释：仅允许`tls`或强制`starttls`，至少TLS1.2并验证受信任根/域名/有效期；不支持关闭验证、可选STARTTLS、远程明文。`local-capture`只接受字面回环IP且不接受SMTP用户名/密码，不能用于远程主机。不擅自使用外部邮件服务、购买服务或向真实第三方邮箱发信；生产凭据由部署者安全配置。

Rust已支持直接TLS1.2/1.3及本地可信CA，配置见[HTTPS](HTTPS.md)；无TLS的HTTP仍强制仅回环。Swift地址、URLSession和ATS均强制HTTPS，邮箱界面仍由`ios_email_auth`接入，不能把旧匿名表单当作邮箱功能完成。

```sh
python3 -m unittest backend.tests.test_email_auth -v
```

测试使用随机隔离PostgreSQL schema、临时Rust HTTP端口与SMTP端口、忽略目录下的临时邮件文件，结束全部清理；真实走SMTP和HTTP，不跳过数据库。三个固定验收命令仍原样保留于README。

实现参考：[RustCrypto Argon2](https://docs.rs/argon2/0.5.3/argon2/)、[lettre SMTP TLS](https://docs.rs/lettre/0.11.23/lettre/transport/smtp/struct.SmtpTransport.html)、[OWASP 邮箱归属验证](https://cheatsheetseries.owasp.org/cheatsheets/Email_Validation_and_Verification_Cheat_Sheet.html)。未执行Apple平台验证，不宣称iOS已支持本模块账号流程。
