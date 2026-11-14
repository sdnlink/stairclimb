# 爬楼梯

原生 SwiftUI iOS 应用 + Python 标准库 HTTP/SQLite 后端的分模块实现。所有楼层都是每 100 步兑换的虚拟游戏楼层，日界线统一为 **Asia/Shanghai**，不采集真实地理位置。

当前已交付第一个模块：可启动的后端、服务器规则、身份认证、昵称和带版本锁的共享状态。累计同步/排行榜/删除、iOS 工程、联网 UI 和最终集成验收将由后续模块完成。当前没有可运行的 iOS 应用，也没有静态假榜单。

## 本地启动

需要 Python 3.10+ 和系统 IANA 时区数据库（当前 Linux Python 3.12.4 已验证）；无第三方 pip 依赖、邮件、手机验证码或付费服务。

```sh
cd /home/skn/code/stairclimb
sh scripts/run_backend.sh
```

默认 `127.0.0.1:8787`，数据库 `.runtime/stairclimb.sqlite3`。前台按 Ctrl-C 停止。可直接传参数，例如 `sh scripts/run_backend.sh --port 8788 --database /tmp/stairclimb.sqlite3`，或参考 [开发配置](backend/development.env.example) 设置 `STAIRCLIMB_HOST`、`STAIRCLIMB_PORT`、`STAIRCLIMB_DATABASE`。文件内没有密钥。

也可复制配置示例、修改后加载；示例中的 `export` 使配置传入启动脚本的子进程（路径含空格时请给值加引号）：

```sh
cp backend/development.env.example .env
# 编辑 .env 后执行：
. ./.env
sh scripts/run_backend.sh
```

```sh
curl --fail --silent http://127.0.0.1:8787/health
```

HTTP 仅供本机/可信局域网开发。真机访问 Linux 需显式监听局域网地址（如 `STAIRCLIMB_HOST=0.0.0.0 sh scripts/run_backend.sh`）并使用电脑可达的局域网 IP；**iPhone 的 127.0.0.1 是手机自己**。远程连接必须通过 HTTPS 反向代理，不要直接将此开发 HTTP 服务暴露公网。后续 iOS Release 配置只允许 HTTPS，Debug 仅允许本地开发例外。

## 验证

固定验收命令（每个测试使用临时数据库和 OS 分配的临时端口，不接触开发实例）：

```sh
python3 -m unittest discover -s backend/tests -p 'test_*.py' -v
```

测试以真实 HTTP 验证两个独立用户、认证、改名、不可指定他人身份、共享/撤回/旧请求重放、并发版本锁、服务重新建立后的持久化、请求体限制和错误响应，并验证换算及上海午夜边界。具体运行证据见 [本模块验证记录](docs/verification-01.md)。接口详见 [API 文档](docs/API.md)。

评审修复后的 23 项回归结果与新增的配置启动验证见 [修复记录](docs/verification-01-repair.md)。

当前 Linux 没有 macOS/Xcode/iOS 模拟器；尚未进行 Swift 编译、签名、真机 HealthKit 或视觉验证。后续交付将补充完整 Xcode 工程、Swift 测试、Linux 静态检查和明确的 Mac 构建/测试命令；这些检查不能代替 Mac/iPhone 实际验证。

监督流程已由外部 Auto Moniter 启动，worker 不修改监督器源码、不提交或暂存 Git。独立 reviewer 和 Watcher 的复核结果由监督流程记录，本 README 不冒称它们已接受实现。
