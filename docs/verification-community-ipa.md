# 2026-11-15 增量验证：交流关闭与IPA构建入口

## 实际执行环境与边界

Linux，无Xcode或iOS模拟器。本次未执行Swift编译、XCTest、真机安装、Apple签名或远程GitHub Actions。脚本的替代Apple工具测试只验证编排和清理，不能用作真实IPA构建证明。原任务第37轮验收不能覆盖这些新代码。

## 已执行

- `python -B -m unittest backend.tests.test_chat -v`：7项通过。真实Rust/PostgreSQL/邮箱验证身份，包含默认关闭和生产入口不可被测试环境变量打开。
- `cargo test --locked --manifest-path backend/Cargo.toml --all-targets`：18项通过。
- `python -B -m unittest discover -s scripts/tests -p 'test_*.py' -q`：57项通过，其中6项为新增IPA编排/描述文件/清理测试；签名脚本描述文件目录兼容调整后又针对性重跑6项通过。
- `python -B scripts/check_ios_project.py`：通过；97个PBX对象，18个应用和7个XCTest源文件均正确关联。
- tree-sitter检查8个修改的Swift源文件，未见ERROR或缺失语法节点；这不是Swift类型检查。
- PyYAML解析新workflow并核对签名模式、macOS runner和只读权限通过；固定版本actionlint v1.7.7检查新IPA workflow通过，全部shell步骤通过bash语法检查。
- `git diff --check`、`cargo fmt --manifest-path backend/Cargo.toml --all -- --check`：通过。

整套后端131项第一次回归发现本机OpenSSL1.1默认配置与`-addext`重复CA扩展，以及迁移003硬编码检查；修复后又发现子进程`python3`指向系统3.7，而项目工具要求3.10+。未降低证书验证。开发CA改用独立配置文件，明确扩展；启动器和相关断言同步迁移004。使用3.12虚拟环境的PATH后，对受影响的交付、圈子交付、邮箱交付、HTTPS四模块重跑23项，全部通过（84.463秒）。其余后端用例在前次131项运行中通过，未把前次失败运行记成整套通过。

## 本地服务实际验证

项目自有HTTPS进程已重新启动，PostgreSQL原数据和既有有效CA保留。`https://127.0.0.1:8787/health`返回健康且`chat_enabled=false`，迁移为1、2、3、4。通过受信任CA校验的HTTPS请求，确认消息GET/POST/DELETE、举报POST、屏蔽GET/PUT共6个入口均返回503 `chat_disabled`。无测试聊天内容写入持续服务。

## 功能状态

- 楼梯动画与浏览、点层、回放代码已保留；需要Mac和iPhone验证。
- 社交文字交流开发代码保留，只能在隔离测试服务显式开启；iOS和生产服务关闭。
- 内容过滤、举报处理运营能力和公开开发者联系信息未就绪，不能开放聊天；详见[CIRCLE_COMMUNITY.md](CIRCLE_COMMUNITY.md)。
- IPA支持Development、Ad Hoc、App Store、unsigned。证书使用既有GitHub变量命名，不读取本地真实证书或打印Secret。实际配置及下载方式见[IPA_BUILD.md](IPA_BUILD.md)。真实构建是否通过必须以首次macOS Actions结果为准。
