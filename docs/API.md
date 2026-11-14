# 爬楼梯 HTTP API

本增量已实现健康接口、注册、本人资料、改名、共享同意与撤回。步数同步、榜单、本人定位和删除接口将在后端社交模块补充，当前不会返回假数据。

## 通用规则

- 基础路径示例：`http://127.0.0.1:8787`（仅本地开发）。远程客户端应连接部署者提供的 HTTPS 反向代理；此标准库服务本身不终止 TLS，不应直接暴露公网。
- JSON 请求须带 `Content-Type: application/json` 和单个有效 `Content-Length`。请求体上限 4096 字节，不接受 chunked。返回 JSON、`Cache-Control: no-store`，每次请求后关闭连接。
- 除健康接口和注册外，用 `Authorization: Bearer <本机凭证>` 认证。注册返回的随机 256 位凭证仅返回一次；数据库只保存 SHA-256 摘要。凭证不得写入 URL、日志、源码或配置。注册默认不共享。
- 所有当前接口拒绝查询参数和未定义字段。没有能指定他人 ID 的写接口；`user_id`、`id`、客户端计算的 `floor` 或隐私状态等额外字段都被拒绝。
- 昵称首尾去除 Unicode 空白后须为 1～24 个 Unicode 码点，可含可见文字、数字、标点、emoji 及内部普通 U+0020 空格；拒绝控制字符、格式字符、换行、非普通内部空白。不要求昵称唯一。
- 共同日区为 `Asia/Shanghai`，不依赖手机或服务器的系统日区。每个正常返回和业务错误包含服务器当日 `date`（YYYY-MM-DD）、`timezone`、带时区的 `day_start`、`day_end`、`steps_per_floor: 100`、`max_steps: 1000000`。
- 后续同步只接受当日累计总数整数（0～1000000，拒绝 bool/浮点/字符串）。楼层由服务端计算 `steps // 100`；距下一层为 `100 - steps % 100`。0/99/100/101 对应 0/0/1/1 层及 100/1/100/99 剩余步数。这是虚拟步数游戏，与健康 App 的实际已爬楼层无关，不收集地理位置。

## 已实现接口

| 方法和路径 | 请求体 | 返回 |
| --- | --- | --- |
| `GET /health` | 无，无需认证 | `200 {status:"ok", ...日界线规则}` |
| `POST /v1/users` | `{"nickname":"小楼"}` | `201 {token, user, ...规则}` |
| `GET /v1/me` | 无 | `200 {user, ...规则}` |
| `PATCH /v1/me` | `{"nickname":"新昵称"}` | `200 {user, ...规则}` |
| `PUT /v1/me/sharing` | `{"enabled":true,"expected_revision":0}` | `200 {user, ...规则}` |

`user` 结构为 `{id, nickname, sharing_enabled, consent_revision}`；资料接口绝不返回 token 或 token_hash。UUID 格式的 id 只用于展示/本人比较，不是授权依据。

只有用户看过「昵称、当日汇总步数及虚拟楼层会对其他用户可见」并主动同意后，客户端才可发送 `enabled:true`。本地 HealthKit 进度与创建身份不等于公开同意。

共享变更采用乐观版本锁：初始 `consent_revision=0`；开关每次实际变化将版本 +1；**每次成功关闭共享也必须将版本 +1，即使原来已经关闭**，以阻止此前尚未到达的开启请求。只有已开启时、版本匹配的重复开启是无副作用操作。`expected_revision` 须为 0～2^63-1 的整数且等于当前版本，否则 `409 consent_changed`。请求不确定是否成功时，先重新 GET 本人资料再更新 UI；**不要自动重新发出开启共享的用户意图**。例如新账号先收到关闭 rev0→1，再收到延迟的开启 rev0，后者返回409；关闭屏障在重启后仍有效。开启 rev0→1、撤回 rev1→2 后，重放旧开启请求也不能恢复共享。下一模块的步数写入必须匹配当前共享版本。

撤回使用 `{"enabled":false,"expected_revision":当前版本}`。服务器持久保存关闭状态；后续模块将从公开榜单排除该账号并拒绝步数上传。撤回与删除保存记录是不同操作。客户端应在用户撤回时先停止自动上传/重试，网络失败须显示仍待服务器完成撤回。

## 错误

响应形状：`{"error":{"code":"invalid_nickname","message":"中文可读说明"}, ...日界线规则}`。HTTP 协议级错误可能只有 `error`。不暴露堆栈、数据库细节或凭证。

| HTTP | code 示例 | 含义 |
| --- | --- | --- |
| 400 | `invalid_json`, `invalid_body`, `invalid_query`, `invalid_request` | 非 JSON 对象、无效 UTF-8、重复字段、NaN、无效协议参数 |
| 401 | `unauthorized` | 凭证缺失、无效或身份不存在 |
| 404 / 405 | `not_found`, `method_not_allowed` | 未实现路径或不支持的方法 |
| 408 | `request_timeout` | 请求读取超过 5 秒 |
| 409 | `consent_changed` | 旧共享版本，请重读资料 |
| 411 / 413 / 414 / 415 | `length_required`, `body_too_large`, `uri_too_long`, `json_required` | 长度缺失、体积/路径过长、类型不匹配 |
| 422 | `invalid_fields`, `invalid_nickname`, `invalid_sharing`, `invalid_revision` | 字段、类型或范围非法 |
| 503 / 500 | `storage_unavailable`, `internal_error` | 临时不可用，不能当作写入成功 |

本地身份没有邮箱、短信或跨设备找回机制。拿到凭证即能操作该身份，凭证遗失不能找回；应用后续使用 Keychain 保存。卸载后 Keychain 是否保留不能作为恢复保证。
