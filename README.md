# 爬楼梯

原生 SwiftUI iOS 应用 + Python 标准库 HTTP/SQLite 后端的分模块实现。所有楼层都是每 100 步兑换的虚拟游戏楼层，日界线统一为 **Asia/Shanghai**，不采集真实地理位置。

当前后端已实现服务器规则、身份认证、昵称、带版本锁的共享状态、当日累计快照、真实分页排行榜、本人定位、隐私删除，以及按每日步数自动匹配的运动圈子。iOS 工程、联网 UI、中文圈子页面和最终集成验收仍由后续模块完成。当前没有可运行的 iOS 应用，也没有静态假榜单。

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

测试以真实 HTTP 验证多用户注册→主动共享→累计同步→全榜分页和本人定位，以及改名、重复同步、并列排序、跨日、非法输入、越权、撤回、删除和服务重建后的持久化。测试也覆盖等待 SQLite 写锁期间跨越午夜、并发上传与隐私操作，以及数据变化后拒绝旧分页。接口详见 [API 文档](docs/API.md)。

评审修复后的 23 项回归结果与新增的配置启动验证见 [修复记录](docs/verification-01-repair.md)。

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

当前 Linux 没有 macOS/Xcode/iOS 模拟器；尚未进行 Swift 编译、签名、真机 HealthKit 或视觉验证。后续交付将补充完整 Xcode 工程、Swift 测试、Linux 静态检查和明确的 Mac 构建/测试命令；这些检查不能代替 Mac/iPhone 实际验证。

监督流程已由外部 Auto Moniter 启动，worker 不修改监督器源码、不提交或暂存 Git。独立 reviewer 和 Watcher 的复核结果由监督流程记录，本 README 不冒称它们已接受实现。
