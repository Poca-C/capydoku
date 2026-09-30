# 构建环境

当前版本 0.2.20 (23)。原 `Capydoku` scheme 保留 Debug / Release 和 `com.capydoku.demo`，继续使用原 Demo 的应用容器。额外提供三套优化构建；它们不包含 `DEBUG` 条件编译代码。

| Scheme | 构建配置 | 环境 | Bundle ID | 桌面名称 |
| --- | --- | --- | --- | --- |
| Capydoku | Debug / Release | internal_demo | com.capydoku.demo | Capydoku |
| Capydoku-TestFlight | TestFlight | testing | com.capydoku.demo.testing | Capydoku 测试 |
| Capydoku-Staging | Staging | staging | com.capydoku.demo.staging | Capydoku 预发布 |
| Capydoku-Production | Production | production | com.capydoku.demo.production | Capydoku 正式候选 |

后三个 Bundle ID 是项目内部占位身份，允许候选包与原 Demo 分别保存本地数据。它们尚未由发布方注册或配置签名。Scheme 名称 TestFlight / Production 不表示已经上传 TestFlight、连接生产服务或具备上架资格。

功能回归测试仅使用原 `Capydoku` scheme 的 Debug 配置。三套候选 scheme 不挂载测试套件；它们通过各自配置的构建、正常启动与环境隔离检查验证，避免把依赖 Debug 测试入口的测试误用于候选包。

`Common.xcconfig` 仅保存版本；各环境文件分别保存环境名称、Bundle ID、显示名及独立能力开关，避免修改公共文件时同时开启全部环境的服务。项目生成器在项目级引用这些文件，App 和测试 target 自动继承对应配置；测试 Bundle ID 使用环境 App ID 加后缀。不要直接修改生成的 `project.pbxproj`，新增 Swift 文件后运行 `python3 scripts/generate_project.py`。

所有环境当前均使用以下设置：

- `CAPYDOKU_REMOTE_CONFIGURATION_ENABLED = NO`，URL 为空。环境匹配值随目标环境变化；没有编造远程服务地址或密钥。
- `CAPYDOKU_ANALYTICS_ENABLED = YES` 仅允许经过用户同意后的本地事件队列。当前没有外部分析 SDK 或数据上传通道。
- 自定义开关在 Info.plist 使用构建变量的 `YES` / `NO` 字符串。运行时负责严格解析，并拒绝未知值；这些不是 Info.plist 原生布尔类型。
- 广告仍使用 Demo 模拟接口，没有真实广告 SDK、广告单元或收入流量。

运行 `python3 scripts/verify_build_environments.py` 可检查 Xcode 实际解析的五种构建配置和四个 shared scheme，输出 JSON 证据。该检查不编译、不安装、不签名，也不验证真实 SDK、广告单元、供应商数据源或发布账号。正式接入时需要再配置并验证发布方的各环境真实身份和服务，签名、真机、隐私与上架验收仍分别进行。
