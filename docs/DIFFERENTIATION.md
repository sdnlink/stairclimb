# 差异化分析与首批路线内容

分析日期及官方来源复核日期：**2026-11-16（Asia/Shanghai）**。源码基线：`926536768317cb8728318604843314e748b76dbb`，加本次 V3A01 的内容、工程资源引用及 Python 校验增量。归属模块：`differentiation_assessment`；派发需求版本3，承接版本2、3的澄清（direction `92934369d4eb46c1b8d7b83eba94a9cd`、`599eed6c5b214af18da6ed21489d8539`）。本报告不改写既有模块定义或接受状态。

**当前仅准备内容，尚未接入 App 旅程入口。** 两条原创路线及其资源阶段引用已交付；没有 Swift 路线解码器、选路页面、节点解锁或完成状态。资源图及 Python 检查通过不能算作旅程功能、原生构建或 Apple 审核通过。

## 原始表述、澄清与验收终点

[原需求](../REQUIREMENTS.md)的原始表述保留为：“将每天自己的运动步数体现在楼梯层数上，联网查看所有用户分别位于哪个楼梯层。”这是现有本机楼梯、联网榜单及每日运动圈子的基础，不能用原创内容取代真实计步、共享同意或真实联网成员。

本次要求保存的人工验收标准原文是：**“你搜索后发现本程序实现的差异化能力足够丰富，不会被AppStore拒收为止”**。最新澄清为：**按源码、功能及真实验证验收，由项目所有者确认丰富程度；Apple审核为外部结果，而非本次完成的前置条件。** 保留原始愿望与澄清，不把它改写成对未来过审的承诺，也不重新询问已解决的验收边界。本项不代替所有者作出“足够丰富”的确认。

本次派发的目标原文是：“交付首批原创路线内容，扩展真实路线数据及App资源绑定校验，并形成有官方来源和源码依据的差异化分析；明确当前仅准备内容，尚未接入App旅程入口。”其明确边界原文包括：“不添加Swift业务实现、远程资源、位置、传感器模拟或账号依赖；不改变scheme，不把Python通过表述为原生功能或Apple审核通过。”

功能验收的终点是实际可用的 App 体验，不能以差异化报告或内容文件替代。按最新派发边界，本项只交付其前置的内容、绑定校验及分析证据；不能把“分析已完成”或“JSON 已被引用”扩写成用户已能使用旅程。真正的 App 旅程体验仍需要实际入口、真实当日快照驱动的节点状态及交互验证，本项没有实施这些工作，也不宣称整体功能完成。Apple 审核结论属于实际审核；本文只识别相关风险，不承诺满足审核、不提交 App Store，也不将 Apple 工具链缺失当作本项内容工作的阻塞。已明确的边界继续执行，无需重新询问。

技术基线以当前源码和后发指令为准：原生 Swift/SwiftUI、Core Motion 本机计步、Rust/PostgreSQL、邮箱认证、HTTPS、上海日界线；旧需求或历史文档中的 HealthKit/Python/SQLite 是历史快照，不恢复为当前实现。

## 官方依据及适用限制

以下为本次实际取得内容的官方页面，均于2026-11-16复核；产品描述只证明公开宣传的能力，未安装竞品实测，不代表穷尽市场或证明本项目独有。

| 来源 | 本次取得的依据 | 分析中的适用范围 |
| --- | --- | --- |
| [Apple App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/) §4.2、§4.3 | 最低功能关注实际效用、内容及持续娱乐价值；同质化类别需要有意义的差异或改进体验 | 换名、换配色或多放一个 JSON 不能直接证明差异化充分。规则没有保证“两条路线”即可获批 |
| 同一[官方指南](https://developer.apple.com/app-store/review/guidelines/) §1.2、§5.1.3 | UGC涉及过滤、举报处理、屏蔽和公开联系渠道；运动与健身数据有用途和披露约束 | 原创编辑内容不等于开放聊天；计步相关隐私要求继续适用，不能因迁出HealthKit就忽略 |
| [Apple Health / Fitness 官方介绍](https://www.apple.com/health/)（旧 `/ios/health/` 重定向至此） | 已有活动目标、进度及趋势；iPhone步数、距离和爬楼数据可用于活动估算 | 数字计步、目标进度并非本项目独有。本项目100步换一层是游戏规则，不等同于实际爬楼 |
| [Apple CMPedometer 官方文档](https://developer.apple.com/documentation/coremotion/cmpedometer.md) | 系统计步及历史查询、实时更新接口，运动用途说明要求 | 当前真实数据源的依据；不是本项目传感器准确性、后台实时性或真机授权通过的证据 |
| [Pacer 官方博客：Virtual Adventure Challenges series is here!](https://www.mypacer.com/blog/virtual-adventure-challenges) | 2026-11-16检索；页面标记更新于**2020-09-03，属于历史资料**。介绍以真实活动推进虚拟长途旅程、限时目标及完成徽章 | 证明2020年已有运动驱动虚拟旅程的产品先例；不能据此确认当前版本的功能、收费或可用性，也未足以判断完整成长统计能力 |
| [StepsApp 官方产品页](https://steps.app/)及[iOS Insights官方支持页](https://production.steps.app/en/support/pedometer/ios/data-and-steps/what-is-the-insights-page) | 2026-11-16检索；目标、连续达标；Insights包含My day、Streaks、Trends、Average day、Totals、Records，可选择步数、热量、距离、时长、楼层 | 支持对目标和成长统计的公开能力对照；支持页未显示发布日期，本文不推断版本或全部功能。所读页面未足以判断叙事虚拟旅程的有无 |
| [Pedometer++ 官方产品页](https://pedometer.app/home) | 步数、楼梯、目标、图表、连续达标与徽章；还介绍地图和路线功能 | 单独把步数换成楼层或增加徽章差异有限；不声称其他产品没有路线 |
| [Walkr 开发者发布的 App Store 产品页](https://apps.apple.com/us/app/walkr-gamified-fitness-walk/id834805518)（SPARKFUL） | 日常步数转换为太空船能量，结合星球探索、任务及社交 | 步行驱动虚拟探索已有先例；本项目只能主张本次中文故事的具体创作，不能主张首创“走路＋故事” |

另尝试[Apple Support 活动圆环目标页面](https://support.apple.com/guide/iphone/adjust-your-activity-ring-goals-iph9a08e004e/ios)：原请求跳转后只能取得导航，正文请求遇到 HTTP 429，**正文未复核，不作为结论依据**。没有用搜索摘要替代该正文。上述可访问页面也仅反映本次取回内容，未来规则或产品能力变动需重新核对。

指定产品的有限对照如下；依据为上表链接，不把页面未提及的能力当作产品不存在的能力。

| 产品与资料范围 | 目标 | 虚拟旅程 | 成长统计与本项目的差异判断 |
| --- | --- | --- | --- |
| Pacer，2020年历史公告 | 限时距离挑战及完成徽章 | 用真实活动数据推进知名长途路线的虚拟探索 | 公告不足以核对完整长期统计。虚拟旅程并非本项目首创，本次中文短篇及具体节点是内容方向，不代表功能丰富程度已超过Pacer |
| StepsApp，2026-11-16取得的官方产品及支持说明 | 每日目标、连续达标 | 本次页面未提供足够依据作有无结论 | 趋势、累计和个人纪录已有公开介绍。仅当日楼层或完成文案不能等同于成长统计；没有实测版本或比较统计准确性 |
| 本项目，当前源码及本次内容增量 | `StepRules`与`ProgressViewScreen.metrics`提供下一虚拟层剩余步数；本次路线节点提供当日累计门槛 | 两条原创中文路线已准备，实际选择、阅读和解锁入口尚未接入 | 当前核对到的是当日进度与成功时间/缓存展示；本项没有新增跨日趋势、累计成就或纪录页面。拟以明确节点叙事及完成反馈增强体验，目标选择、长期成长反馈仍属后续产品方向，不能计入已实现能力 |

## 当前源码基线与拟增强方向

| 范围 | 当前可审查源码 | 差异化判断与后续方向（尚未实施部分明确列出） |
| --- | --- | --- |
| 真实计步与日界线 | [StairClimbApp.swift](../ios/StairClimb/App/StairClimbApp.swift)、[MotionStepReader.swift](../ios/StairClimb/Motion/MotionStepReader.swift)、[LocalAppModel.swift](../ios/StairClimb/App/LocalAppModel.swift)、[ShanghaiDay.swift](../ios/StairClimb/Core/ShanghaiDay.swift) | 已有本机系统汇总及上海当日状态。计步本身是基础能力；拟议旅程应只派生真实快照，不造步数、不模拟传感器、不增加定位或账号前置条件 |
| 楼梯交互 | [StepRules.swift](../ios/StairClimb/Core/StepRules.swift) 的 `StepRules` / `StaircaseRules`、[ProgressViewScreen.swift](../ios/StairClimb/Views/ProgressViewScreen.swift) 的 `StaircaseView` | 当前100步/虚拟层，最多1,000,000步；已有有限跨层动画、浏览、回到我、只读回放及缓存提示。拟把具体叙事与节点门槛相连，避免只有换皮数字；实际旅程入口、选择、阅读与完成反馈尚未接入 |
| 榜单与每日小圈 | [SocialView.swift](../ios/StairClimb/Views/SocialView.swift)、[CircleView.swift](../ios/StairClimb/Views/CircleView.swift)、[SocialModel.swift](../ios/StairClimb/Network/SocialModel.swift) | 当前为真实成员、1000步区间、主动同意、每日重配；可提供同日运动背景。旅程不依赖凑人数、假圈友或强制公开；本项未给圈友绑定任何旅程数据 |
| 原创编辑内容 | [ClimbJourneys.json](../ios/StairClimb/Resources/ClimbJourneys.json) | 本次新写两种完整微叙事：邮局送信、图书馆种子成长。具体节点有场景、轻量心中活动和收束文案；没有借用竞品故事。未来应通过真实阅读/回访反馈评估内容价值，目前没有留存率或可用性实验，不能宣称差异化已获用户验证 |
| 实际入口边界 | [SocialView.swift](../ios/StairClimb/Views/SocialView.swift) 的 `AppShell.body` | 当前只有“我的楼梯”“今日楼层榜”“运动圈子”三个 Tab；本次未改 Swift。JSON进入资源图不使其自动成为可读页面，不能声称用户已可选路、解锁或完成旅程 |

差异化方向是“短篇中文叙事＋清楚的虚拟楼层门槛＋可独立阅读的节点”，并保留真实计步及不公开也可本地使用的基础。两条路线是内容试制规模，不足以证明长期内容供给、持续娱乐价值或市场独特性。拟议节点完成应区分新鲜快照与缓存、处理上海跨日并避免重复累计；这些是后续实现时应验证的方向，本项只校验静态契约。

## 聊天关闭状态保留

聊天继续关闭：[CircleChannel.swift](../ios/StairClimb/Core/CircleChannel.swift) 的 `CommunityFeatures.chatEnabled = false`，`CircleView` 受该开关控制，`SocialModel.canChat` 同样受限。[backend/src/http.rs](../backend/src/http.rs) 仅允许显式隔离测试启用聊天；[backend/src/chat.rs](../backend/src/chat.rs) 在关闭时返回503 `chat_disabled`。这是本次源码核对，不是重新探测运行中服务。

已有开发代码不代表开放或完成UGC要求；过滤、举报运营、公开联系方式及平台验证等限制继续见[运动圈交流状态](CIRCLE_COMMUNITY.md)。原创路线是随包编辑内容，没有评论、上传、聊天或远程内容依赖，本次不改变聊天开关。

## v1 内容契约与逐节点审阅

UTF-8标准JSON，根对象仅有 `schemaVersion`（精确整数1）及 `routes`（至少两条）。路线字段为 `id`、`title`、`summary`、`completionText`、`nodes`（至少三个）；节点字段为 `id`、`title`、`story`、`requiredSteps`、`completionText`。路线与节点的文案均须为非空白字符串，路线级 `completionText` 收束整条旅程。v1拒绝未知字段、重复JSON键、`NaN` / `Infinity` / `-Infinity`；新增契约需要明确版本处理，不静默吞掉拼错字段。

路线ID在路线集合内唯一；节点ID在**各自路线内唯一，不同路线允许复用节点ID**，节点由路线ID与节点ID共同定位。所有ID为1–64字符，首位为ASCII字母或数字，其余允许ASCII字母、数字、点、下划线和连字符：`[A-Za-z0-9][A-Za-z0-9_.-]{0,63}`，例如 `A_1.2` 合法。已发布ID保留其叙事含义，编辑文案不应换ID或在同一路线内把旧ID复用于另一节点。数组顺序就是叙事顺序；字典字段顺序无语义。

`requiredSteps` 是**当日累计步数门槛**，不是额外增加的步数或实际爬楼层。范围按当前 `StepRules` 校验为100至1,000,000（含端点），必须是100的整数倍，各路线内严格递增；不同路线可有相同门槛。布尔值、浮点数（包括100.0）、零、负数和越界值均拒绝。最大值只是既有数据上限，并非推荐运动目标；本次内容只用100至900步。

逐一内容审阅结果如下；完整原文位于JSON的 `story` 和 `completionText`，均为本次原创，而不是“节点1/完成”等占位文本。心中活动只是可选阅读提示，唯一数据门槛是累计步数，不收集回答，也不验证现实位置。

| 路线 / 稳定节点ID | 累计门槛 / 虚拟层 | 实质叙事 | 完成文案的具体收束 |
| --- | --- | --- | --- |
| 雨后邮局 / `rain-post-office-eaves` | 100 / 1层 | 檐下雨滴、守信人、用今天的声音写第一行 | 声音装进信封，盖第一枚水纹邮戳 |
| 雨后邮局 / `rain-post-office-sorting-room` | 300 / 3层 | 风吹纸角、无地址的信、在心里放下一件小事 | 小事收进格子，信封变轻，屋顶门打开 |
| 雨后邮局 / `rain-post-office-rooftop` | 600 / 6层 | 布旗与虚构天际线、给明天自己的祝愿 | 信到屋顶，三枚邮戳连路，明确旅程完整 |
| 种子图书馆 / `night-seed-library-drawer` | 200 / 2层 | 种子目录柜、想象种子颜色与临时名字 | 生成目录卡，点亮第一盏灯 |
| 种子图书馆 / `night-seed-library-reading-room` | 500 / 5层 | 月光书页与未萌发根系、无需计时的停留 | 夹好月光书签，显现温室楼梯 |
| 种子图书馆 / `night-seed-library-greenhouse` | 900 / 9层 | 玻璃晨光、小叶、允许停止且无未完惩罚 | 小叶接光，前三站成册，图书馆合上 |

两条路线另各有非空的路线级 `completionText`：邮局以集齐邮戳、送达屋顶收束，图书馆以目录卡、书签和小叶合册收束。本次修复只增加这一整条路线文案，六个节点的叙事、门槛及完成文案原样保留。

## 资源引用及本次验证证据

[project.pbxproj](../ios/StairClimb.xcodeproj/project.pbxproj) 只增加JSON文件引用、PBXBuildFile、Resources组及App资源阶段成员；未改scheme、Swift源文件或target配置。实际链路：`PBXProject.targets → StairClimb PBXNativeTarget.buildPhases → PBXResourcesBuildPhase.files → PBXBuildFile.fileRef → 主组解析后的 StairClimb/Resources/ClimbJourneys.json`。文件位于错误目录、同名替身、孤立对象或仅测试target资源阶段都不能满足此链路。该链路证明工程声明会复制资源；实际App包内容尚未通过原生构建检查。

[check_project](../scripts/check_ios_project.py) 使用已有解析引用图验证这个链路及正常构建资源阶段，再校验内容；复用已核对Swift/Rust/参考实现一致的步数常量作为范围。保持原有全部检查与六项返回，包括末项静态验证限制，没有将路线内容加入Swift业务逻辑。

行为失败基线先于校验器改动取得：先放入合法JSON及正确App资源绑定，运行声明的新测试文件中的 `test_valid_project` 和 `test_rejects_empty_node_story`；合法项目成功，随后仅把第一个节点 `story` 改为三个空格。旧函数未抛出 `CheckFailure`，拒绝断言真实失败：`AssertionError: CheckFailure not raised`，2项测试中1项失败，退出1。测试成功启动且合法夹具先通过，失败原因不是缺文件或环境问题。

首轮候选的worker曾运行 `auto:1` 对应入口：28项通过、1.742秒、退出0；这只证明当时的测试覆盖，未发现后来评审指出的契约偏离，不能作为修复候选或Watcher接受的证据。上面的空白 `story` 行为失败基线继续保留。

本次有限修复先补齐合法路线 `completionText` 并增加 `test_complete_v3_contract_accepts_legal_ids_and_cross_route_node_reuse`：使用合法路线ID `A_1.2`、`0`，两条路线复用节点ID `N_1.2`，期望真实 `check_project` 返回六项。修复校验器前，该测试成功启动，因 `routes[0] ('A_1.2') unknown fields: ['completionText']` 抛出 `CheckFailure`，1项测试以1个error失败、退出1。这是把合法内容误拒绝的行为失败，不是环境或缺文件失败。恢复路线完成文案、约定ID字符集和路线内节点唯一性后，同一数据及返回六项断言通过。

修复后实际运行派发 `auto:1` 指定的 `local_test_runner.py`（项目为当前checkout，路径 `scripts/tests/test_journey_catalog.py`，runner `unittest`）：**32项通过，2.003秒，退出0**。测试读取实际交付JSON、调用真实 `check_project`，在临时项目覆盖：

- 完整合法契约返回六项；100和1,000,000合法门槛通过，路线间允许复用门槛；字母/数字开头、大小写、点/下划线/连字符、1及64字符合法ID和跨路线同名节点通过。
- 路线 `completionText` 缺失、空白及错误类型失败；JSON语法/UTF-8、根结构/版本、必填文案及类型、路线和节点数量、非法ID、重复路线ID或路线内重复节点ID、门槛顺序/类型/倍数/范围、重复键和非标准数值都失败，并检查文件或路线/节点定位原因。
- 文件存在而未入App资源阶段、只入测试target、PBXBuildFile指向另一现存资源、同名不同路径、孤立资源阶段、仅部署后处理资源阶段，以及缺失文件都失败。

固定检查 `check:1` 为 `git diff --check`；本次最终执行退出0。未执行未声明的测试套件、原生构建、XCTest、签名、IPA导出或真机操作；`scripts/tests/test_ios_project.py`及其他既有受保护测试文件和断言保持原样。仅修正本项尚未接受的新测试中错误的“小写slug”和“跨路线节点不得同名”假设，保留其余有效负向断言。当前提交候选交由Watcher按声明检查及独立评审接受，本报告不代替它们的结果。

## 派发验收项的文件证据索引

下表只索引 V3A01 范围内证据，归属模块均为 `differentiation_assessment`，不宣称整体需求或后续旅程功能完成。

| 派发 criterion_id | 本项实际证据 |
| --- | --- |
| `differentiation_assessment:1` | 本文的2026-11-16日期、Pacer（2020年历史文章）及StepsApp指定产品官方来源、适用限制、源码基线与有限对照 |
| `differentiation_assessment:2` | `ClimbJourneys.json` 两条原创路线、六个节点及本文逐节点审阅 |
| `differentiation_assessment:3` | `check_ios_project.py` 的真实资源图与约定内容契约校验，`test_journey_catalog.py` 的32项聚焦验证及本文限制披露 |
| `req:1:1` | 本文保留“你搜索后发现本程序实现的差异化能力足够丰富，不会被AppStore拒收为止”原文及按源码/功能/真实验证、由所有者确认丰富程度、Apple审核属外部结果的最新澄清；未把内容准备算作App功能完成 |
| `req:1:2` | 本文Pacer、StepsApp的官方链接、检索日期和目标/虚拟旅程/成长统计有限对照，Pacer标为2020年历史资料；保留§4.2/§4.3分析及未复核来源限制 |
| `req:1:3` | `ClimbJourneys.json` 具体中文叙事、门槛和完成文案；本文拟增强方向 |
| `req:1:5` | `ClimbJourneys.json`及校验器恢复路线级非空 `completionText`、约定ASCII ID和路线内节点唯一性；保留最小PBX引用，无Swift/位置/传感器模拟/账号或远程资源增量 |
| `req:1:9` | `test_journey_catalog.py` 的原空白story及本次合法完整契约行为失败基线、修复后32项通过及边界断言；本文保留聊天关闭、原生平台及审核未验证限制 |
