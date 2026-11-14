# backend_identity 评审修复记录

本轮仅处理 AUD-1、AUD-2，不扩展其他模块；worker 提供修复与证据，是否关闭审计问题由独立 reviewer 决定。原始 [20 项验证记录](verification-01.md) 及其日志保持不变。

## 复现与修复

- AUD-1：修复前，新增 HTTP 回归在新账号执行 `false/rev0` 后实际得到 `rev0`，`assertGreater(revision, 0)` 失败。`backend/storage.py` 现让每次成功关闭都在原事务中推进版本，既有开启幂等规则保持不变。测试覆盖关闭先于延迟开启、关闭后 GET、重建服务后拒绝旧开启，以及重复关闭建立新屏障。`docs/API.md` 同步明确关闭的版本副作用。
- AUD-2：修复前，清除三项预存环境变量后加载示例，子进程读取三项均为 `None`，与配置值不符。`backend/development.env.example` 现显式 export 三项变量，README 补充加载方式。新增 `backend/tests/test_launcher.py` 验证加载到子进程，并复制示例为临时配置，使用临时数据库和 `port=0` 实际启动脚本，通过分配端口的 HTTP `/health` 确认服务可用，检查数据库位于自定义路径，最后停止进程并清理。

## 实际命令与结果

环境：Linux，Python 3.12.4。两项修复前复现用例退出 1，`Ran 2 tests / FAILED (failures=2)`；复现均与评审判断一致。

修复后针对性命令：

```sh
python3 -m unittest backend.tests.test_identity.IdentityHTTPTests.test_close_before_delayed_enable_creates_persistent_version_barrier backend.tests.test_launcher -v
```

退出 0，`Ran 3 tests in 0.156s / OK`。

随后仅执行一次相关完整回归：

```sh
python3 -m unittest discover -s backend/tests -p 'test_*.py' -v
```

退出 0，`Ran 23 tests in 0.597s / OK`。完整实际输出保存于 [backend-identity-repair.txt](validation/backend-identity-repair.txt)。`sh -n scripts/run_backend.sh backend/development.env.example` 与 `git diff --check` 均退出 0。

所有新增运行验证均使用临时 SQLite、临时端口，不访问正常开发实例。未执行 iOS 构建、签名或真机验证；剩余原始模块由既有 ledger 保留。本轮没有暂存、提交、修改 Git refs 或监督器源码。
