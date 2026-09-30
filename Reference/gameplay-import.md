# 冻结玩法配置导入

本接口对应原文 1.1、2.2、7.4、8.1–8.5。当前没有收到冻结版 Pawdoku 的逐关配置与采样档案，因此 `gameplay-template.json` 明确为 `awaiting_baseline`，150 关配置全部是 `null`，不能用于控制游戏。不得把演示参数填进这个文件后冒充冻结值。

每一行的完整字段见 `gameplay-row-worksheet.json`。该表内的 `null` 表示待提供资料，不是 0、false 或默认值。填好原始导入文件后，将状态改为 `frozen`，填写配置版本及 baseline 的商店版本、UTC 采样时间、设备、系统、归档文件 SHA256 与证据文件名称；`importedSourceSHA256` 留 null，由导入器写入。150 个关卡均需要独立配置，不允许自动向后复制未知关卡。

字段包括每关生命、directFind/hint 的开启和显示状态、解锁关、初始库存、首次解锁赠送、跨关保留和重新发放策略、广告开关；关卡开始免费广告的入口、奖励、次数、重置与顺序；复活、失败文案和流程；插页的起始关、频率、冷却与超时。`evidenceID` 记录实际录屏或配置的定位，允许明确记录经观察为关闭的功能。关闭横幅无需假定上线配置；开启横幅必须有另行评审证据。

`inventoryAcrossLevels` 是 `retain` 或 `reset`。`regrantPolicy` / `resetPolicy` 是 `once_per_level`、`every_attempt` 或 `never`。这些枚举表示读取到的策略，不规定本项目应选哪个值。

运行方式：

```sh
python3 scripts/import_reference_gameplay.py /path/to/frozen-source.json \
  --output Resources/reference-gameplay.json \
  --report Validation/reference-gameplay-import.json \
  --previous /path/to/previous-imported-baseline.json
```

第一次导入省略 `--previous`。后续更新必须提供上一版进行逐字段差异审查；同一 configVersion 下内容改变会被拒绝。脚本只在完整校验通过后写入输出，失败不会覆盖已有生产文件。报告包含来源字节校验值、输出校验值、版本、150 关覆盖结果、错误和字段差异。输入中任何未知字段都会拒绝，包括 Region Map、答案、Opening State 或原始棋盘；这些数据绝不能成为本项目生产输入。

客户端通过 `ReferenceGameplayConfiguration.load(data:expectedSHA256:)` 读取，`isReadyForUse` 为 true 才能通过 `level(_:)` 获得配置。可用冻结清单中的输出 SHA256 校验打包文件。配置更新应仅在新对局或下次启动时生效；进行中的对局继续使用其已保存配置版本。导入器不证明采样来源真实性，正式冻结仍须人工复核证据并批准。

导入框架与测试完成不等于已与 Pawdoku 对标。Tests/Fixtures 中的 synthetic 行仅用于错误输入和导入流程测试，不得打包为业务配置。

## 客户端缓存与远程接入

`GameplayConfigurationStore` 已接入 AppModel，负责启动时读取配置、后台拉取、校验和缓存。启动先读取有效缓存；主缓存损坏时尝试有效备份，均不可用时保留包内默认值。缓存记录配置内容、版本、拉取时间和已接受的版本校验值，并校验缓存整体完整性。远程响应在后台校验和原子写入成功后才发布给应用；网络失败、超时、非法响应或写入失败均保留原可用配置，不弹出阻塞首页或游玩的错误。

这一流程的前置条件是包内已有完整、有效、状态为 `frozen` 的 `Resources/reference-gameplay.json`。远程响应的冻结 baseline 必须与包内批准的 baseline 一致，不能通过联网替换参考产品、商店版本、采样证据或归档校验值。缺少包内基线、仅提供空模板或包内文件校验不通过时，不读取远程配置作为替代基线，也不发起远程请求；应用继续使用明确标注的 Demo 临时配置。

配置按 `platform`、`appVersion`、`environment` 联合隔离，缓存使用独立命名空间，响应也必须与请求目标完全一致。当前默认目标为 `iOS`、安装包 `CFBundleShortVersionString` 和 `internal_demo`；这不表示预发布与正式环境的服务、App ID、广告位或数据源已经配置。不同应用版本不会直接复用这一命名空间中的缓存，后续如需迁移须另行定义并验证。

当前没有提供真实服务地址。默认 HTTP 接入只读取 Info.plist 的 `CapydokuRemoteConfigURL`，且仅接受不带用户名和密码的 HTTPS 地址；未配置有效地址时不联网，不使用示例网址代替。供应商 SDK 到位后，也可通过 `GameplayConfigurationProvider` 接入其实际拉取接口。启动拉取和回到前台时的重试均不等待网络结果再进入首页；进行中的请求不会重复发起，普通拉取尝试之间设置基于单调时钟的 30 秒技术退避，显式重试可跳过退避。该时长不是 Pawdoku 的玩法或广告频控参数。

## HTTP 内部草案合同

以下仅为目前客户端可执行的内部适配合同，**不是供应商已经确认的格式**。正式服务或 SDK 接入时须逐项对齐请求、响应、超时和取消行为，不能据此宣称外部联调完成。

HTTP 适配器使用 GET，请求查询参数如下：

| 参数 | 含义 |
| --- | --- |
| `platform`、`app_version`、`environment` | 当前配置目标，须与返回的 target 一致 |
| `baseline_sha256` | 已批准包内 baseline 的 `sourceArchiveSHA256` |
| `config_version` | 当前可用配置版本 |
| `revision` | 当前已接受的远程修订号；仅使用包内配置时为 0 |

成功响应必须是 JSON 对象，且仅含以下五个字段；`target` 也不得带额外字段：

| 字段 | 格式与约束 |
| --- | --- |
| `schemaVersion` | 整数，当前为 1 |
| `target` | 对象，包含 `platform`、`appVersion`、`environment`；注意响应采用 `appVersion` 而非请求参数的 `app_version` |
| `revision` | 正整数；旧于已接受修订号的响应拒绝，同一修订号不得改内容 |
| `configurationData` | **原始配置 JSON 字节的 Base64 字符串**，对应 Swift `Data` 的编码；不是嵌套 JSON 对象，也不是重新序列化后的摘要 |
| `sha256` | 对 Base64 解码后的原始 JSON 字节计算的 SHA256，小写十六进制字符串 |

解码后的配置仍必须通过完整的 150 关冻结配置验证，禁止未知字段、棋盘答案、区域地图及其他关卡数据。相同 `configVersion` 不得对应不同内容：客户端保存已接受版本与原始字节 SHA256 的映射，正常重启后继续校验；只改空白或字段顺序也会改变原始字节校验值，须按版本规则处理。提高 `revision` 不能绕过版本不可复用规则。校验值证明字节一致性，不代替对采样来源真实性的人工复核。

## 生效边界与诊断

异步更新只替换下一次新局可选用的配置。`start(level:)` 创建新对局时取得一次配置快照；继续当前对局、返回首页再进入、Restart 和重启恢复都保留已有 session 的配置。广告请求及奖励台账使用发起时的对局和奖励快照，新配置即使关闭广告或修改奖励数量，也不会改写已经进行中的广告或重复发放奖励。

问题定位导出新增 `gameplayConfiguration`，包含目标、来源（`unavailable`／`bundled`／`cache`／`remote`）、配置版本、修订号、拉取时间、是否正在刷新、最近错误和是否从备份恢复。导出中的 `referenceGameplay` 是后续新局候选，`progress.session.config` 才是当前对局实际使用的快照；两者在更新后不同属于预期行为。

当前冻结配置模型仅定义前 150 关。151 关后的实验生成仍使用 Demo 配置，其广告总开关、免费次数和其他远程策略尚未定义；不能把前 150 关的配置接入结果算作后续实验关卡的完整验收，也不能擅自复制第 150 关参数。真实冻结资料、服务地址、供应商协议／SDK、三套发布环境和真实网络联调仍待交付与验证。任何 synthetic 测试数据都不得写入 Resources 充当正式基线。
