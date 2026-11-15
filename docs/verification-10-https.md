# https_transport 当前版本交审

需求版本7仍为`0f0b02550ca7868604bdb2b3c4a4bd9d0d0887041c6572f956de80a4d3c87f37`；起始HEAD为`3cf9e4c2d2a71d6af49ff57b3d9d2fca493183e2`，上轮worker checkpoint为`39aa9f7dba46a4ac814cc5fd0a5e967d272589b4`。先核实工作区及既有证据，保留AUD-5修复和六模块业务审计。本轮只推进下一必交模块`https_transport`，不重写不可变模块定义，不修改Auto Moniter源码、状态、历史或Git引用。

Rust直接TLS复用现有HTTP解析器及业务路由，新增`backend/src/tls.rs`，仅TLS1.2/1.3及HTTP/1.1；无TLS仍只准回环，双路径配置不完整、证书非法/密钥不匹配启动失败，不回退明文。握手前64连接过载分支直接关闭，不发明文503；握手与请求I/O有5秒超时，握手失败归还连接计数。明文原有拒绝响应的有界关闭逻辑保留。

`scripts/dev_tls.py`创建私有开发CA及短期SAN证书，只写忽略目录，目录700、文件600，不安装设备或系统信任，不覆盖既有CA。`backend/https.env.example`无真实私钥。启动、LAN域名/IP、CA安装及停止见[HTTPS.md](HTTPS.md)，README与API同步。没有公网部署、购买服务、注册账号或向外部邮箱发信。

Swift统一严格HTTPS，移除Debug ATS全部例外，Release继续默认ATS；URLSession至少TLS1.2，保留系统信任、不自定义证书认证，禁止重定向，APIClient发送前重新验证根地址。新增Swift测试源码覆盖本地HTTPS、所有HTTP及直接构造客户端旁路拒绝。工程检查/隔离结构回归改为拒绝所有HTTP例外；后发HTTPS要求覆盖此前Debug私有HTTP的默认，不弱化其他断言。既有本机HealthKit/Keychain/日期/楼梯逻辑未改。

## 已完成聚焦检查

| 命令 | 实际结果 |
| --- | --- |
| `cargo check --locked --manifest-path backend/Cargo.toml --all-targets --features test-support` | 退出0 |
| `python3 -m unittest backend.tests.test_https -v` | 11项通过，14.118秒，退出0；[HTTPS聚焦日志](validation/https-focused.txt) |
| `python3 -m unittest backend.tests.test_https.HTTPSTests.test_trusted_ca_tls12_and_tls13_health backend.tests.test_https.HTTPSTests.test_development_ca_reuse_permissions_and_overwrite_guard -v` | 更新后的正式二进制TLS及证书CLI/配置导出2项通过，1.759秒，退出0；[日志](validation/https-production-cli.txt) |
| `python3 scripts/check_ios_project.py` | 退出0；91个对象、16个应用及6个XCTest源文件；实际工程、HealthKit及严格HTTPS配置关联通过 |
| `python3 -m unittest discover -s scripts/tests -p 'test_*.py' -v` | 25项通过，退出0；与工程检查一起见[结构日志](validation/https-ios-structure.txt) |
| `git diff --check` | 退出0 |

真实HTTPS检查包括可信CA成功、TLS1.2/1.3分别协商、无信任/错误CA、域名不符、过期、非法/部分/不匹配证书、明文及旧TLS拒绝、过载握手无明文、失败后容量归还、加密错误JSON/体积上限，以及两个邮箱用户经Rust/PostgreSQL/隔离SMTP完成注册验证登录、主动共享、同步、真实榜单/圈友。所有证书和邮件仅存私有临时忽略目录，结束清理。测试有意尝试旧TLS导致Python弃用提示，不表示降级成功。

当前源码和配置指纹见[https-sources.sha256](validation/https-sources.sha256)，历史源码清单及日志保留，不伪装为新版本。只运行一次完整相关后端回归，三个固定命令继续保留，外部Watcher仍自行检查候选；最终结果追加于下表，不以旧日志冒称本轮检查。

| 最终实际命令 | 结果 |
| --- | --- |
| `python3 -m unittest discover -s backend/tests -p 'test_*.py' -v` | 103项通过（原92项+11项HTTPS），182.349秒，退出0；[完整回归](validation/https-regression-1.txt) |
| `cargo test --locked --manifest-path backend/Cargo.toml --all-targets` | 14项通过，0忽略，退出0；[Rust回归](validation/https-regression-2.txt) |
| `cargo fmt --manifest-path backend/Cargo.toml --all -- --check` | 退出0；[格式检查](validation/https-regression-3.txt) |
| `sha256sum -c docs/validation/https-sources.sha256` | 56项匹配，退出0；清单摘要`b484c6c336941670c88da1fb936c68685b5d1f5bfd2827bc582ba1cd03379f79` |

另实际执行公开CA的PEM→DER导出并比较证书SHA-256指纹，完全一致，退出0，见[导出记录](validation/https-ca-export.txt)；没有安装全局或设备信任。独立reviewer `/root/tls_candidate_review` 已只读复核实现、文档、完整日志及56项源码指纹，未发现阻断缺口；未代替外部Watcher登记接受。

## 审计分类及未执行平台验证

上轮外部审计正文已经接受六模块并关闭AUD-5，却将“此限制不阻断本轮后端接受”的Apple工具链缺失放入blockers，从而触发AUD-7 `Done was reported with unresolved external blockers.`。这是结论分类问题，没有复现新的后端缺陷，不据此改写已接受业务。AUD-6/AUD-7交由独立reviewer依据原需求的Linux交付边界修正分类，worker不自行关闭ID，也不修改监督状态。

Apple工具链、Mac/iPhone验证仍未执行：Swift编译、XCTest、系统ATS、签名、HealthKit及视觉/断网/午夜/圈子交互。原需求明确允许继续交付完整源码及Linux可验证部分；本模块接受不表示这些平台检查通过。限制在证据和README保留，不将它冒充本后端/TLS源码模块的新外部阻塞，不重复尝试已知不可用工具。

未完成的`ios_network`、`ios_circles`、`ios_email_auth`、`backend_data_access`、`ios_freshness`、`apple_build_validation`及`delivery_validation`、`circles_delivery`、`email_auth_delivery`继续保留。Swift旧匿名表单尚待邮箱UI替换，已有HTTP地址不会发送请求或被自动改为新服务，Keychain身份和隐私意图不丢弃。最终持续Rust/PostgreSQL/HTTPS实例仍由最终交付模块提供，本轮不以测试进程代替最终运行交付。
