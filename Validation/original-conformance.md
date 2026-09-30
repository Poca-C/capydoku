# 原始需求逐项符合性记录

本记录以原始 Word V1.3 正文及附图为依据。结论：**可内部试玩，部分符合；冻结参考、外部接入和上架尚未验收。** 后续报告和旧 Checklist 不覆盖原文。

原文校验值：`274bbf15f031bd80bb8b360cf14c0266acff370a230d9cad1b1785461df54dd2`。原文[n]对应 [document.txt](../Reference/Original/document.txt) 的0-based正文块索引（含表格），不是页码。83行是实质要求分组，不是完成率。

## 状态含义

- `implemented`：已实现及检查代码，尚无完整当前构建证据。
- `verified`：只验证本行明确描述的行为，仍须阅读缺口。
- `awaiting_reference`：缺冻结参数、素材或样本。
- `external_pending`：缺外部服务或发行条件，不免除客户端责任。
- `partial`：实现、对接或验证仍有缺口。

## 证据边界

- 旧88项Checklist的完成数字与originalRequirementsPreserved标志不作为原文符合性证据；旧版报告只保留历史。
- 当前150+30严格生产完成，180唯一答案及不同区域结构，无相似性豁免；数值Profile仍未经Pawdoku校准，跨产品语料缺失。
- 原文只固定L1为4×4；本地早期尺寸安排不能覆盖原文的去重要求。
- 最终截图已目视核对；当前包页面、教学及L10流程有测试，但不声称与尚未提供的冻结录屏逐帧一致。
- 真实广告SDK由外部供应；客户端入口、配置、库存、复活和奖励安全仍是本Demo责任。
- Daily Challenge保留锁定入口，Profile明确不做。正式原音频、真实SDK、真机及上架均待验。

## 后续处理项

- **CLIENT-01 · P1 · Do not accept unimplemented imported behavior silently**：triggerOrder is not executed; restartCreatesNewBoard is not implemented as a complete alternate-board path. Frozen capture must settle behavior; current unsupported state must be explicit. 已加明确未支持提示及原局不变测试；换盘正式路径和triggerOrder语义仍待冻结资料。
- **CLIENT-02 · P2 · Complete audio playback/configuration contract**：Current manifest has volume/delay/concurrency/loops but no complete page applicability, loop-point or fade policy; bulk swipe audio can be suppressed by the minimum interval. Actual reference audio is missing. Add mappings/timing support alongside the supplied original audio; remain silent and unverified before assets arrive.
- **CLIENT-03 · 本地已验证 · 广告位加载与展示合同**：已接按广告位预热/ready/展示/立即补载；offer落盘后才展示，超时覆盖等待ready，重复/过期回调隔离，启动完成前禁用广告；插页失败及超时可继续且不发奖。13项最终专项及兼容测试通过。 正式逐关广告位表、真实SDK、单元缓存及网络性能待联调。
- **CLIENT-04 · 已验证 · One-time state corruption recovery**：同意/通关/挑战状态已迁移SHA校验双副本，主文件损坏回退测试通过；旧主存档与归档棋盘升级恢复通过。 保留真机中断和长期存储压力的正式验收。
- **CLIENT-05 · P2 · Touch target and focus audit**：签到38pt已修为至少44×44，并以17e实际UI尺寸与单行测试验证。 保留全局焦点恢复、长英文、动态字体和对比度的专项验收。

## 1 · 参考基线

| ID／原文索引 | 要求与状态 | 实现和证据／仍缺内容 |
|---|---|---|
| REF-01<br>[5] [7] | 冻结 Pawdoku 唯一参考版本及资料<br>`awaiting_reference` | 已保存原 Word 正文、28 张附图及原文校验值。<br>**缺口：**缺商店版本、完整录屏、采样设备/系统、正式配置和音频清单；Word 附图不能替代完整冻结基线。<br>[document.json](../Reference/Original/document.json) · [document.txt](../Reference/Original/document.txt) · [gameplay-template.json](../Reference/gameplay-template.json) |
| REF-02<br>[8] | 150 关玩法与商业化映射<br>`partial` | 定义并接入逐关 direct/hint、免费广告、复活、失败与插页配置模型；失败标题/按钮/关闭、免费复活配额已补接。<br>**缺口：**真实逐关值尚缺；triggerOrder、restartCreatesNewBoard 的精确语义和执行路径仍待冻结，不可称全字段执行完毕。<br>[ReferenceGameplayConfiguration.swift](../Sources/CapydokuCore/ReferenceGameplayConfiguration.swift) · [AppModel.swift](../App/AppModel.swift) · [PlayerProgress.swift](../Sources/CapydokuCore/PlayerProgress.swift) |
| REF-03<br>[9] | 结构化导入与禁止导入参考棋盘<br>`verified` | 导入脚本严格拒绝未知字段/棋盘/答案，验证完整 150 关、来源校验值、字段类型；7 个 Swift 和 6 个 Python 测试通过。<br>**缺口：**验证的是导入契约，未收到真实冻结数据，不能据此声称对标完成。<br>[import_reference_gameplay.py](../scripts/import_reference_gameplay.py) · [test_import_reference_gameplay.py](../scripts/test_import_reference_gameplay.py) · [ReferenceGameplayConfigurationTests.swift](../Tests/CapydokuCoreTests/ReferenceGameplayConfigurationTests.swift) · [reference-gameplay-import.json](../Validation/reference-gameplay-import.json) |
| REF-04<br>[10] | 基线变更控制<br>`implemented` | 支持上一版本字段差异及同版本内容变更拒绝。<br>**缺口：**实际冻结、人工评审和版本更新记录尚无。<br>[import_reference_gameplay.py](../scripts/import_reference_gameplay.py) · [gameplay-import.md](../Reference/gameplay-import.md) |
| REF-05<br>[32] [33] [34] [36] | 原创棋盘与高还原英文主题<br>`partial` | 棋盘自研生成、英文 UI 已重排为原文层级，使用原创 2D 角色。<br>**缺口：**难度、Rank 节点、弹窗节奏及冻结录屏逐项对标尚未完成。<br>[GenerationPipeline.swift](../Sources/CapydokuCore/GenerationPipeline.swift) · [RootView.swift](../App/Views/RootView.swift) · [SupportingViews.swift](../App/Views/SupportingViews.swift) |

## 2 · 核心玩法与道具

| ID／原文索引 | 要求与状态 | 实现和证据／仍缺内容 |
|---|---|---|

## 3 · 关卡生成与验证

| ID／原文索引 | 要求与状态 | 实现和证据／仍缺内容 |
|---|---|---|

## 4 · 界面与视觉

| ID／原文索引 | 要求与状态 | 实现和证据／仍缺内容 |
|---|---|---|

## 5 · 音频

| ID／原文索引 | 要求与状态 | 实现和证据／仍缺内容 |
|---|---|---|
| AUDIO-01<br>[314] [316] [317] [318] [319] [320] [321] [322] [323] [346] | 仅使用原音频及逐文件校验<br>`awaiting_reference` | 移除自制音频和系统配音，音频 manifest 明确 referenceVerified=false。<br>**缺口：**原音乐、效果音、Combo 音频及清单全部未提供，当前缺失事件保持静音；音乐功能不能记为完成。<br>[audio-manifest.json](../Resources/audio-manifest.json) · [FeedbackPlayer.swift](../App/Services/FeedbackPlayer.swift) |
| AUDIO-02<br>[324] [325] [326] | 音乐页面范围、循环、淡入淡出与恢复<br>`partial` | 播放器支持音量、loop、开关、暂停恢复及系统音频中断处理。<br>**缺口：**适用页面映射、循环点、切换/淡入淡出参数尚无实现或资源基线，必须补齐后逐项验证。<br>[FeedbackPlayer.swift](../App/Services/FeedbackPlayer.swift) · [audio-manifest.json](../Resources/audio-manifest.json) |
| AUDIO-03<br>[327] [328] [329] | 有效按钮点击映射与节流/并发<br>`partial` | 统一按钮样式触发点击反馈，manifest 支持最小间隔和并发。<br>**缺口：**目前在按下时触发，取消触摸仍可能触发；缺原按钮白名单及无效/禁用状态音频规则，不能全局统一认定匹配。<br>[CapyStyle.swift](../App/Views/CapyStyle.swift) · [FeedbackPlayer.swift](../App/Services/FeedbackPlayer.swift) |
| AUDIO-04<br>[330] [331] [332] [333] [334] [335] [336] | 单格/连拍/撤销/正确/错误事件<br>`partial` | 仅有效标记、撤销、提交扣命触发对应事件；连拍按新增 X 数量调用。<br>**缺口：**原逐格时序、滑动停止/中断处理及双击声音优先级未参考资源验证；连拍批量调用可能被minimumInterval压掉。<br>[AppModel.swift](../App/AppModel.swift) · [PuzzleBoardView.swift](../App/Views/PuzzleBoardView.swift) · [FeedbackPlayer.swift](../App/Services/FeedbackPlayer.swift) |
| AUDIO-05<br>[337] [338] [339] [341] [342] [343] | Combo 阈值、分组及四开关<br>`awaiting_reference` | 四开关保存，播放器按manifest group控制声效/语音，Combo 文本与事件存在。<br>**缺口：**阈值、默认开关、延迟、分组、音量均无冻结值；当前demo参数不可当参考验收值。<br>[DemoConfig.swift](../Sources/CapydokuCore/DemoConfig.swift) · [GameSession.swift](../Sources/CapydokuCore/GameSession.swift) · [FeedbackPlayer.swift](../App/Services/FeedbackPlayer.swift) |
| AUDIO-06<br>[344] [347] [348] [349] | 不新增声音及完整音频回归<br>`partial` | 代码避免新增胜利音/奖励声，缺正式素材时不播放替代声音。<br>**缺口：**静音不等于音频通过；原资源未到，所有开关组合、广告/后台及快速滑动需真机听测。<br>[FeedbackPlayer.swift](../App/Services/FeedbackPlayer.swift) · [audio-manifest.json](../Resources/audio-manifest.json) |

## 6 · 数据与分析

| ID／原文索引 | 要求与状态 | 实现和证据／仍缺内容 |
|---|---|---|

## 7 · 平台、SDK与存档

| ID／原文索引 | 要求与状态 | 实现和证据／仍缺内容 |
|---|---|---|

## 8 · 广告与商业化

| ID／原文索引 | 要求与状态 | 实现和证据／仍缺内容 |
|---|---|---|

本表与 [本轮验证记录](original-verification.json) 配合阅读；历史测试失败保留，仅明确标注的通过重验计入证据。
