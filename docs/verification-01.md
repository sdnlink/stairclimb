# 模块一：后端身份、规则与共享状态验证

本记录由 implementation worker 生成，供独立 reviewer / Watcher 复核；不是 reviewer 接受结论。

## 环境与范围

- 工作目录：`/home/skn/code/stairclimb`，Linux，`python3 --version` 实际输出 `Python 3.12.4`。
- 检查 `/proc/*/cmdline` 后确认已有本工作区的 `python -m auto_moniter run --resume` 进程，PID `307828`；复用该流程，没有启动重复实例，没有修改 Auto Moniter 源码或 `.auto-moniter` 记录。
- 本模块新增 `backend/domain.py`、`backend/storage.py`、`backend/server.py`、`backend/tests/test_identity.py`、启动脚本、无密钥开发配置、README 和 API 文档。
- 本模块不交付步数同步/排行榜/删除或 iOS 应用；这些归后续模块。没有把测试服务器当成最终持续运行的交付实例。

## 已执行

```sh
python3 -m unittest discover -s backend/tests -p 'test_*.py' -v
sh -n scripts/run_backend.sh
python3 -m backend.server --help
git diff --check
```

最终固定测试命令退出码 **0**，实际执行 **20 项测试**，`Ran 20 tests in 0.446s / OK`。完整实际 stdout/stderr 保存在 [backend-identity.txt](validation/backend-identity.txt)。其余三个命令退出码也为 0。没有使用正常开发数据库或固定开发端口。

HTTP 测试通过 `make_server(..., port=0)` 创建真实 TCP listener，每个测试拥有临时目录和独立 SQLite 数据库，并在结束时关闭服务器、等待线程退出、清理目录。持久化测试明确 shutdown/server_close 后建立新的服务实例，复用同一临时数据库，通过 HTTP 验证两用户的有效凭证、改名、同意和撤回状态保留。

覆盖：

- 0/99/100/101/12789/1000000 的楼层和距下一层，步数非法类型和范围；UTC 15:59:59 与 16:00:00 对应上海年末/次年午夜。
- 两个独立身份注册默认不共享、凭证隔离、本人资料不含认证摘要、缺失/伪造凭证与未认证写入。
- 昵称裁剪、24 码点边界、Unicode 非法字符、错误验证无副作用；客户端传入另一个 `user_id` 或访问他人写路径均被拒绝。
- 明确共享开关、版本检查、撤回、旧开启请求重放、四个并发请求只接受一个合法版本变更。
- 超限 body、Content-Type、chunked、缺失/重复/负数/超长 Content-Length、错误 JSON、重复 JSON 键、非标准常量、无效 UTF-8 和未知字段。
- 数据库不可用返回可重试的 503，恢复后身份仍有效；错误响应没有内部路径或 SQLite 信息。
- 数据库、WAL 等文件未保存原始凭证，HTTP 处理没有访问日志输出。

## 下一模块依赖

步数模块应复用认证身份、上海日界线和共享版本，服务端权威验证日期并保存累计快照。`leaderboard_revision` 已预留用于数据变化时让分页游标失效，避免静默漏用户。后续应补充完整真实 HTTP 社交流程、iOS 与最终持续实例的验收证据。

本模块没有运行或宣称通过任何 iOS 编译、签名或真机 HealthKit 验证；当前环境没有对应 Apple 工具链。
