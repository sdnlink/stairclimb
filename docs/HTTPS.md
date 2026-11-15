# HTTPS 通信与本地证书

Rust服务直接通过rustls终止TLS，只支持TLS1.2和TLS1.3，ALPN为HTTP/1.1。配置`STAIRCLIMB_TLS_CERT`及`STAIRCLIMB_TLS_KEY`后，该监听端口只接受TLS，不另开明文端口；任意一项缺失、证书损坏、密钥不匹配会启动失败，不降级HTTP。无TLS配置时，明文HTTP仍只能监听字面回环IP，专用于内部测试，不能作为iPhone连接路径。原请求体上限、错误JSON、会话鉴权与隐私事务保持。

Swift的Debug和Release均仅接受HTTPS根地址，所有旧本机/局域网HTTP及ATS例外已移除。APIClient发送前再次验证根地址，要求URLSession最低TLS1.2，保留系统证书链、域名、有效期校验，不实现自定义信任回调，禁止跟随重定向传送凭据。HTTP旧地址不会自动升级或发送凭据；现有Keychain身份及待办不被删除，客户端邮箱/旧身份迁移界面仍由`ios_email_auth`接通。

## 开发证书与启动

需要OpenSSL、Rust/Cargo及本任务PostgreSQL。不购买域名、证书服务或注册外部账号，工具不会修改机器/设备的信任库。以下创建私有开发CA、ECDSA P-256服务密钥和30天SHA-256证书，所有文件置于忽略目录`.runtime/tls`，目录700、文件600：

```sh
cd /home/skn/code/stairclimb
python3 scripts/dev_tls.py --name stairclimb.local
python3 scripts/postgres_dev.py start
. ./.runtime/postgres.env
. ./.runtime/tls/server.env
sh scripts/run_backend.sh
```

默认TLS监听127.0.0.1:8443，仍由本项目`backend/target/debug/stairclimb-server`运行。可用`sh scripts/run_backend.sh --port 8787`选原默认端口；端口占用时选空闲端口，不停止无关进程。前台Ctrl-C停止本进程，数据库仅用`python3 scripts/postgres_dev.py stop`。邮箱捕获另按[认证说明](EMAIL_AUTH.md)启动和配置，不向外部邮箱发信。

开发证书的SAN含`stairclimb.local`、`localhost`及127.0.0.1，可在Linux实际验证：

```sh
curl --fail --silent --cacert .runtime/tls/ca.pem https://127.0.0.1:8443/health
openssl x509 -in .runtime/tls/ca.pem -noout -fingerprint -sha256
```

不要用`curl -k`、关闭验证的SSLContext或URLSession信任旁路。`ca.pem`是可以交给自有开发设备的公开根证书；**ca-key.pem、server-key.pem不能发送到手机或提交仓库**。脚本重复相同参数会复用CA，不覆盖已有密钥；不同SAN使用新的忽略目录，不静默轮换已安装的信任。证书30天过期后需在新的私有目录重新生成并安装新CA，或由开发者自行使用已有CA签发新证书；本工具没有自动续期或公网ACME功能。

## iPhone访问Linux

127.0.0.1在iPhone指手机自身。使用Linux真实局域网地址，例如确认电脑为192.168.1.3后：

```sh
python3 scripts/dev_tls.py --directory .runtime/tls-lan --name stairclimb.local --ip 192.168.1.3
. ./.runtime/postgres.env
. ./.runtime/tls-lan/server.env
sh scripts/run_backend.sh --host 192.168.1.3 --port 8443
```

应用填写`https://192.168.1.3:8443`，证书SAN必须包含实际IP。地址变化须重新签发，不能忽略证书错误。若使用`https://stairclimb.local:8443`，需局域网DNS或已有mDNS正确解析到Linux；脚本不会配置DNS、mDNS、hosts或网络接口。主机防火墙应仅允许所需本地网络访问，本项目不更改系统防火墙或对公网部署。

可将公开根证书导出为便于设备安装的DER `.cer` 文件，仍然不要导出私钥：

```sh
openssl x509 -in .runtime/tls-lan/ca.pem -outform DER -out .runtime/tls-lan/ca.cer
openssl x509 -inform DER -in .runtime/tls-lan/ca.cer -noout -fingerprint -sha256
```

仅在自己的开发设备安装公开`ca.cer`，核对与`ca.pem`相同的SHA-256证书指纹。iPhone完成描述文件安装后，还需在“设置→通用→关于本机→证书信任设置”对该开发根证书开启完全信任；安装本身不代表TLS信任。[Apple安装证书信任说明](https://support.apple.com/en-us/102390)说明了该区别。Mac可在钥匙串访问中导入公开CA并设置信任；模拟器也需其独立信任配置。这里提供操作说明，**本环境没有执行Mac/iPhone安装或系统ATS连接验证**。使用结束后移除自己安装的开发CA及信任；删除`.runtime`文件不会自动撤销设备上的信任。

## 自备正式证书

[https.env.example](../backend/https.env.example)只包含路径和监听配置，没有真实私钥或凭证。部署者可将自备、受系统信任且覆盖实际服务域名的叶证书及中间证书链放入私有PEM文件，配置两项TLS路径后启动同一Rust服务。客户端按常规系统信任连接，不接受任意CA或过期证书。正式私钥在部署者受控目录保存，不写入源码或日志。本任务没有购买、注册、申请公网证书或公网部署。

## 可复现检查及限制

```sh
python3 -m unittest backend.tests.test_https -v
python3 scripts/check_ios_project.py
python3 -m unittest discover -s scripts/tests -p 'test_*.py' -v
```

HTTPS测试实际使用Rust、隔离PostgreSQL schema、临时服务端口、私有测试CA和回环SMTP捕获。覆盖正常TLS1.2/1.3、错误CA/域名/过期、非法及不完整证书配置、明文/旧TLS拒绝、过载握手不发送明文、失败后容量归还，以及两邮箱用户注册→验证→登录→主动共享→同步→真实榜单/圈友。结束清理专属临时证书、邮件、进程及schema。固定三个交付命令继续原样执行，不以测试专用匿名入口证明正式认证。

Swift测试源码增加本地HTTPS、所有HTTP拒绝及直接APIClient旁路拒绝，关联原XCTest target；Linux检查实际Debug/Release配置、无ATS例外、TLS下限、发送前复验、默认信任和禁重定向，并通过修改临时工程验证检查器。旧的“允许Debug私有HTTP”断言由更严格的“全部拒绝”替代，未删除与新规则无关的回归。

依据[Apple URLSession TLS下限](https://developer.apple.com/documentation/foundation/urlsessionconfiguration/tlsminimumsupportedprotocolversion)、[Apple ATS与证书检查](https://developer.apple.com/documentation/security/preventing-insecure-network-connections)及[rustls StreamOwned](https://docs.rs/rustls/0.23.46/rustls/struct.StreamOwned.html)实现。Linux的TLS成功不等于iOS URLSession/ATS、Swift编译、XCTest、签名、真机HealthKit或视觉交互通过；README保留Mac命令，`apple_build_validation`继续提供后续自动化入口。未执行的平台验证是原需求允许披露的限制，不是本模块已复现的代码缺陷。
