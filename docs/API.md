# 爬楼梯 HTTP API

已实现健康接口、注册、本人资料、改名、共享同意/撤回、累计同步、真实分页排行榜、本人定位、全部共享步数删除、账号删除及每日运动圈子。圈子规则由追加需求决定，删除共享步数现在同时关闭共享与参与；早期验证记录保留当时契约，不代表现行删除行为。

正式实现为 Rust＋PostgreSQL；启动时应用版本化SQL迁移。历史 Python/SQLite 日志仅作迁移前参考，运动字段及隐私契约保持兼容；正式认证升级为邮箱验证与可撤销会话，见[邮箱认证API](EMAIL_AUTH.md)。

## 通用规则

- 基础路径示例：`https://127.0.0.1:8443`（可信本地CA）。Rust直接终止TLS1.2/1.3；客户端所有开发/正式通信均HTTPS且正常校验证书。配置见[HTTPS](HTTPS.md)。无TLS的HTTP只能用于回环内部测试，不允许局域网明文。
- JSON 请求须带 `Content-Type: application/json` 和单个有效 `Content-Length`。请求体上限 4096 字节，不接受 chunked。返回 JSON、`Cache-Control: no-store`，每次请求后关闭连接。
- 除健康及邮箱认证公开入口外，用 `Authorization: Bearer <access会话凭据>` 认证。正式注册需要邮箱验证，登录/刷新返回access与refresh，数据库仅存摘要。旧匿名凭证仅用于绑定和必要的本人隐私管理，不能绕过正式认证。凭据不得写入URL、日志、源码或配置。注册和验证默认不共享。
- 仅排行榜及当前圈子 GET 接口接受下文列出的查询参数；其他接口拒绝查询参数。所有接口拒绝重复查询键和未定义字段。没有能指定他人 ID 的写接口；`user_id`、`id`、客户端计算的 `floor`、原始健康 `samples` 或来源设备等额外字段都被拒绝。
- 昵称首尾去除 Unicode 空白后须为 1～24 个 Unicode 码点，可含可见文字、数字、标点、emoji 及内部普通 U+0020 空格；拒绝控制字符、格式字符、换行、非普通内部空白。不要求昵称唯一。
- 共同日区为 `Asia/Shanghai`，不依赖手机或服务器的系统日区。每个正常返回和业务错误包含服务器当日 `date`（YYYY-MM-DD）、`timezone`、带时区的 `day_start`、`day_end`、`steps_per_floor: 100`、`max_steps: 1000000`、`circle_band_steps: 1000`。
- 同步只接受当日累计总数整数（0～1000000，拒绝 bool/浮点/字符串）。楼层由服务端计算 `steps // 100`；距下一层为 `100 - steps % 100`。0/99/100/101 对应 0/0/1/1 层及 100/1/100/99 剩余步数。这是虚拟步数游戏，与健康 App 的实际已爬楼层无关，不收集地理位置。

## 已实现接口

| 方法和路径 | 请求体 | 返回 |
| --- | --- | --- |
| `GET /health` | 无，无需认证 | `200 {status:"ok", ...日界线规则}` |
| `POST /v1/users` | 历史昵称注册 | 正式返回403；仅测试专用匿名回归夹具返回201 |
| `GET /v1/me` | 无 | `200 {user, ...规则}` |
| `PATCH /v1/me` | `{"nickname":"新昵称"}` | `200 {user, ...规则}` |
| `PUT /v1/me/sharing` | `{"enabled":true,"expected_revision":0}` | `200 {user, ...规则}` |
| `PUT /v1/me/steps` | `{"date":"2026-11-14","steps":101,"expected_revision":1}` | `200 {progress, consent_revision, ...规则}` |
| `GET /v1/me/steps` | 无 | `200 {progress, consent_revision, ...规则}`，仅本人当日已存值 |
| `GET /v1/leaderboard` | 无；查询参数 `limit`、`cursor` | `200 {items, total, limit, snapshot, next_cursor, ...规则}` |
| `GET /v1/leaderboard/me` | 无；查询参数 `limit`、`snapshot` | `200 {entry, page_cursor, total, limit, snapshot, ...规则}` |
| `DELETE /v1/me/steps` | `{"expected_revision":当前版本}` | `200 {deleted_days, user, ...规则}` |
| `DELETE /v1/me` | `{"expected_revision":当前版本}` | `200 {deleted:true, ...规则}` |
| `GET /v1/me/circle-participation` | 无 | `200 {participating, user, ...规则}` |
| `PUT /v1/me/circle-participation` | `{"enabled":true,"expected_revision":当前版本}` | `200 {participating, user, ...规则}` |
| `GET /v1/circles/current` | 无；查询参数 `limit`、`snapshot` | 当前频道、人数及本人定位 |
| `GET /v1/circles/current/members` | 无；查询参数 `limit`、`cursor`、`snapshot` | 当前频道的分页圈友 |
| `GET /v1/circles/current/me` | 无；查询参数 `limit`、`snapshot` | 当前频道本人及所在页游标 |

`user` 结构为 `{id, nickname, sharing_enabled, consent_revision}`；资料接口绝不返回 token 或 token_hash。UUID 格式的 id 只用于展示/本人比较，不是授权依据。

只有用户看过「昵称、当日汇总步数及虚拟楼层会对其他用户可见」并主动同意后，客户端才可发送 `enabled:true`。本地 HealthKit 进度与创建身份不等于公开同意。

共享变更采用乐观版本锁：初始 `consent_revision=0`；开关每次实际变化将版本 +1；**每次成功关闭共享也必须将版本 +1，即使原来已经关闭**，以阻止此前尚未到达的开启请求。只有已开启时、版本匹配的重复开启是无副作用操作。`expected_revision` 须为 0～2^63-1 的整数且等于当前版本，否则 `409 consent_changed`。请求不确定是否成功时，先重新 GET 本人资料再更新 UI；**不要自动重新发出开启共享的用户意图**。例如新账号先收到关闭 rev0→1，再收到延迟的开启 rev0，后者返回409；关闭屏障在重启后仍有效。开启 rev0→1、撤回 rev1→2 后，重放旧开启请求也不能恢复共享。步数写入必须匹配当前共享版本。

撤回使用 `{"enabled":false,"expected_revision":当前版本}`。服务器在同一事务持久保存关闭状态并使旧榜单分页失效，后续榜单排除该账号，上传被拒绝。撤回与删除保存记录是不同操作：记录保留为本人私有，重新主动共享后仍保留的当日数据会再次公开。客户端应在用户撤回时先停止自动上传/重试，网络失败须显示仍待服务器完成撤回。其他用户已看到或自行保存的数据无法被服务器收回。

## 当日累计快照

`date` 必须为真实存在的严格 YYYY-MM-DD 且等于服务器权威上海当日；非法格式或日期返回 `422 invalid_date`，合法的过去/未来日期返回 `409 day_changed` 并附新日界线。客户端应丢弃旧日待同步值，重新按返回的上海区间读取 HealthKit，不能仅替换旧请求的日期后重试。服务器在取得 PostgreSQL 写锁后重新取时钟，排队跨午夜的请求也执行该规则；无 HTTP/CLI 改时后门。

`expected_revision` 不匹配返回 `409 consent_changed`；匹配但未同意共享返回 `403 sharing_required`。`(user_id,date)` 是唯一主键，使用累计值**替换**已有值，绝不相加。HealthKit 修正后更小的合法快照也会替换；同版本的不同快照按服务器事务先后、最后一次成功写入为准。客户端应串行化同步，不在新值之后重试旧快照。重复相同快照不改变记录、`updated_at` 或榜单版本。

`progress` 示例：`{"steps":101,"floor":1,"remaining_steps":99,"synced":true,"updated_at":"2026-11-14T10:30:00+00:00"}`。没有当日记录时 GET 返回 0/0/100、`synced:false`、`updated_at:null`，不会把昨日记录当成今日值；撤回后本人仍可读取私有保存值。`updated_at` 是带时区的服务端时间。

## 排行榜、分页和本人定位

注册后的任何已认证用户都可查看，无需先同意上传自己的健康汇总。仅 `sharing_enabled=true` 的账号公开；没有今日记录者以 0 步/0 层纳入总数，不隐藏未同步用户。

`items` 是实际 PostgreSQL 数据，每项为 `{user_id,nickname,steps,floor,remaining_steps,rank,position,is_me}`，不包含认证信息、共享版本或健康明细。按步数降序，步数相同按不可变 `user_id` 字典升序。`rank` 为竞赛名次，例如步数 500/200/200/0 对应 1/2/2/4；`position` 为稳定的 1/2/3/4 顺序，定位和分页使用 position。`is_me` 由认证身份计算。

- `limit` 默认20，范围1～100，须为十进制整数。首页不传 cursor；使用返回的 `next_cursor` 继续并保持相同 limit，直到 `next_cursor:null`。例：`GET /v1/leaderboard?limit=2&cursor=<next_cursor>`。小容量可遍历全部可共享用户；无用户时 items=[]、total=0。
- `snapshot` 标识「上海日期 + 持久榜单版本」。每页的认证、版本、总数和排名在同一个 PostgreSQL 读事务快照中计算。步数实际变化、改名、共享变化、隐私删除均使旧游标失效；跨日也失效。返回 `409 leaderboard_changed` 时清空已收集页面并重新请求首页，不能将不同 snapshot 的页拼在一起。相同快照重复同步不会使分页失效。持续变化期间可能需多次刷新，MVP 不保留历史公开快照。
- `GET /v1/leaderboard/me?limit=2` 返回本人 entry 和所属页的 `page_cursor`，即使本人不在首页。可选传当前榜单的 `snapshot` 以要求一致版本，过期返回409。用同样 limit 和 page_cursor 请求 `/v1/leaderboard` 即到本人所在页（包括第一页）；page_cursor 不是下一页游标。
- 未共享/已撤回者的本人定位返回 `entry:null,page_cursor:null`，不将该用户强行公开。游标是无凭证的只读继续标记，不是身份授权；缺损、越界或改页容量返回 `422 invalid_cursor`。未知/重复查询参数返回400。

## 隐私删除

两个 DELETE 都须发送 application/json 请求体（含 Content-Length），且仅接受 `expected_revision`，不接受目标用户 ID。服务端事务内认证与核对版本，失败无副作用。

`DELETE /v1/me/steps` 删除本人**全部日期**的共享记录，`deleted_days` 是被删日期数量。保留身份、昵称，**同时关闭共享与圈子参与**，榜单和圈友列表移除本人。每次成功删除都持久推进 `consent_revision`（空删除也推进），旧上传及旧开启请求返回409，不能复活已删记录。返回 user 包含新版本及 `sharing_enabled:false`。本条由新增产品要求加强，替代此前“保留共享开关”的默认规则；客户端应立即停止本机上传/重试，并在服务器确认前显示待完成。未来恢复上传须重新主动共享，再读取当日健康数据；恢复圈子还须另行主动同意参与。

`DELETE /v1/me` 删除本人身份、昵称、共享状态及所有关联日期记录；该事务提交后旧凭证永久401，延迟上传、开启请求或重复删除均不能复活账号。不影响其他用户，重启不恢复已删除内容。没有恢复接口；相同昵称重新注册得到全新身份。

网络超时或503不代表删除成功。客户端须保留待确认状态并读取服务端状态确认；删除步数重试不能盲目更新版本后重放（可能误删后来新同步），账号重复删除的401须结合本次已发起删除的状态处理。客户端应协调在途上传、撤回和删除。

## 每日圈子与参与隐私

圈子默认区间宽度集中定义于 `backend/src/domain.rs:CIRCLE_BAND_STEPS=1000`，不是地理位置、随机或好友分组。同组=同圈子=同日频道。标识例如 `2026-11-14:0-999`、`2026-11-14:1000-1999`。最大合法步数1000000落在1000000–1000999区间，但仍拒绝超过1000000的步数；区间标签不改变步数上限。

注册和旧共享账号默认不参加圈子。客户端必须先明确告知“按每日步数区间匹配，昵称、当日汇总步数及虚拟楼层将被圈友看到”，让用户主动选择。`PUT /v1/me/circle-participation` 开启须已有有效共享同意，且匹配当前 `consent_revision`；缺少同意403，版本过期409。实际开启推进版本；同版本重复开启幂等。关闭参与**同时关闭健康汇总共享**，每次关闭均推进持久版本，包括已关闭时，以阻断延迟开启与上传；撤回共享也清除圈子参与。用户可以再次主动只开启排行榜共享，但不会自动恢复圈子；圈子必须再单独主动同意。客户端不能自动重试开启意图。

所有圈子 GET 均须身份凭证。未参加者返回 `participating:false,circle:null,total:0,items:[],entry:null,page_cursor:null,next_cursor:null`，不会公开自身或得到圈友名单；已参加者只取当日所属频道。试图提交其他日期、channel或user_id查询参数均400，不能通过客户端指定圈子或写入人数。共享但没有今日记录的参与者按0步进入0–999圈。

当前圈子和本人定位响应为 `{participating:true,circle,total,entry,page_cursor,limit,snapshot,consent_revision,...规则}`。`circle` 为 `{id,date,min_steps,max_steps,band_steps}`；`entry` 和圈友项为 `{user_id,nickname,steps,floor,remaining_steps,position,is_me}`，按步数降序、用户ID升序稳定排序。`total` 是频道当前真实人数；单人圈直接显示一人，不凑人数。摘要与成员读取在一个PostgreSQL REPEATABLE READ读事务快照内完成。未参加时人数为0；正常参加者含本人，至少一人。

成员响应为 `{participating:true,circle,total,items,next_cursor,limit,snapshot,consent_revision,...规则}`。`limit` 同排行榜（默认20、1–100），不传cursor取首页；保持相同limit逐页请求到next_cursor=null。`/me` 或当前圈子摘要返回本人的page_cursor，用于直接加载本人所在页。可选snapshot要求与已加载页面一致。

圈子游标绑定**日期、频道区间、全局榜单版本、页容量**，不能套用别区间或旧日频道。同步变化、改名、参与/撤回和删除使旧分页返回 `409 circle_changed`，客户端清空旧页并重新取当前圈子；跨区间迁圈或跨日也必须刷新。全局版本可能因其他圈变化保守失效；重复相同步数不失效。损坏游标、越界位置或修改页容量422。旧参与者撤回后带旧cursor返回409，不继续透露原圈数据。

每日清零和重配在每次请求按上海日期直接从当前记录派生，不依赖准点任务、打开App或手动清零。没有昨日频道复用或昨日行覆盖为0；无今日行就取0。当天快照跨1000边界自动迁圈，旧圈成员即不再包含此人。成员不另存可漂移的多圈关系或计数，重复/并发不会生成额外成员；记录和主动同意持久保存，服务重启一致。生产不开放改时接口或历史频道访问。

## 错误

响应形状：`{"error":{"code":"invalid_nickname","message":"中文可读说明"}, ...日界线规则}`。HTTP 协议级错误可能只有 `error`。不暴露堆栈、数据库细节或凭证。

| HTTP | code 示例 | 含义 |
| --- | --- | --- |
| 400 | `invalid_json`, `invalid_body`, `invalid_query`, `invalid_request` | 非 JSON 对象、无效 UTF-8、重复字段、NaN、无效协议参数 |
| 401 | `unauthorized` | 凭证缺失、无效或身份不存在 |
| 403 | `sharing_required` | 尚未主动同意共享，拒绝上传 |
| 404 / 405 | `not_found`, `method_not_allowed` | 未实现路径或不支持的方法 |
| 408 | `request_timeout` | 请求读取超过 5 秒 |
| 409 | `consent_changed`, `day_changed`, `leaderboard_changed`, `circle_changed` | 旧共享版本、非当日快照或榜单/圈子已变化；重读资料/健康数据/首页 |
| 411 / 413 / 414 / 415 | `length_required`, `body_too_large`, `uri_too_long`, `json_required` | 长度缺失、体积/路径过长、类型不匹配 |
| 422 | `invalid_fields`, `invalid_nickname`, `invalid_sharing`, `invalid_participation`, `invalid_revision`, `invalid_steps`, `invalid_date`, `invalid_limit`, `invalid_cursor`, `invalid_snapshot` | 字段、类型或范围非法 |
| 503 / 500 | `storage_unavailable`, `internal_error` | 临时不可用，不能当作写入成功 |

本机UUID仍无恢复接口；旧匿名凭证丢失不能凭user_id找回。完成邮箱验证的账号可通过邮件重置密码；会话需由客户端Keychain安全保存，卸载后Keychain是否保留不能作为恢复保证。认证API、429限流及503邮件错误详见[邮箱认证说明](EMAIL_AUTH.md)。
