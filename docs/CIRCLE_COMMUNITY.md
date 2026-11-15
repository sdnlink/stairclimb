# 运动圈交流（开发中，暂时关闭）

2026-11-15：按项目所有者要求，聊天功能暂时关闭。iOS不展示聊天入口，`canChat`始终为false；正式Rust服务的消息、举报、屏蔽接口统一返回503 `chat_disabled`，不会写入消息。健康检查返回`chat_enabled: false`。每日步数组圈和成员列表继续提供。

已有开发代码包括同频道文字消息、回复、自己撤回、消息分页、增量更新、举报记录、双向屏蔽及取消屏蔽。消息只在iOS内存保存，不写入UserDefaults或Keychain。网络沿用HTTPS和邮箱验证会话；服务端在用户行锁后重新验证会话、共享、圈子资格、上海日期和步数区间，拒绝跨圈及跨日的旧请求。客户端关联身份、频道与日期，隐私操作和迁圈会清除缓存。

这些代码是未开放的开发基础，不代表已经满足Apple UGC要求或通过App审核。内容过滤、举报处理工作流、处理通知和时限、审核审计、公开且有效的开发者联系方式仍未完成。举报记录目前仅入库，不存在自动通知、人工排班或处理SLA。关闭状态下不会收集新聊天或举报内容。开发者联系信息尚未提供，不能以示例邮箱替代真实联系方式。

重新开放之前必须完成并验证：

1. 服务端内容过滤、可维护词库和适当的人工复核，覆盖不当内容、骚扰与霸凌，处理变体与误拦截；不能以简单词表保证内容安全。
2. 用户举报入口、可操作的待处理队列、举报通知、明确处理责任人和响应时限，以及删除内容、限制违规账号、处理反馈和审计记录。
3. 屏蔽、取消屏蔽及骚扰防护；屏蔽和撤回共享后，其他已打开客户端也应在刷新时清理相关缓存。
4. 公开开发者联系方式、社区规则、隐私说明和主动同意；验证联系渠道实际可用。
5. 坚持运动交流定位及验证账号体系，不提供匿名随机聊天；明确禁止色情内容、骚扰和霸凌。
6. Xcode编译、XCTest、真机交互和多账号端到端验证。

## 隔离开发验证

只有专用`stairclimb-test-server`进程在以`test-support`编译且显式设置`STAIRCLIMB_TEST_CHAT=1`时能访问开发接口。生产入口`stairclimb-server`始终关闭，即使误设该变量也不会打开。测试fixture会清除继承的测试开关，只为本文件的测试显式启用。不需要在本地持续服务中设置此变量。

```sh
python3 -m unittest backend.tests.test_chat -v
```

测试使用真实PostgreSQL、Rust HTTP、邮箱验证账号和隔离SMTP捕获器；无外部邮件发送。覆盖多账号收发、回复、撤回增量、分页、举报去重、双向屏蔽、取消屏蔽、退出后隐藏、账号删除关联清理、并发幂等、频率限制、跨圈、跨日，以及锁等待期间会话撤销。另验证默认关闭和正式入口无法被测试开关打开。iOS当前只能进行静态工程和语法检查，本环境无Xcode，不能声称运行过iOS或XCTest。

## 数据与接口（仅隔离测试）

迁移004建立`circle_messages`、`circle_blocks`、`circle_reports`和消息变化序列；迁移以事务和既有迁移锁执行，可重复启动。账号删除级联清除关联消息、举报和屏蔽关系。撤回消息清空正文，但保留撤回占位。历史消息尚无定期清理作业；跨日或迁圈后不能通过当前频道接口访问旧频道，不能把这理解为数据库已删除历史记录。

| 方法与路径 | 用途 |
| --- | --- |
| GET /v1/circles/current/messages | circle_id必填，limit为1–50，before消息ID向前分页，after变化序列增量读取，before和after互斥 |
| POST /v1/circles/current/messages | circle_id、text、reply_to（可为null）、client_id（UUID）；同一UUID及相同内容重试不重复写入 |
| DELETE /v1/circles/current/messages | circle_id、message_id，仅撤回自己在当前圈的消息 |
| POST /v1/circles/current/reports | circle_id、message_id、reason（spam/abuse/other），同人对同消息去重 |
| GET /v1/circles/current/blocks | circle_id必填，只返回自己的屏蔽列表 |
| PUT /v1/circles/current/blocks | circle_id、user_id、enabled，双向隐藏聊天，不影响排行榜 |

消息正文限制1000个Unicode标量，最多5条/10秒；消息POST最多16KiB，兼容中文、表情和JSON转义，其他写接口仍为4096字节。消息返回昵称和不透明账号ID，不包含邮箱、凭证或原始健康数据。相同client_id不同内容或已撤回消息的重试返回409。客户端不自动重放写请求。
