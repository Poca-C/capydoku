# Capydoku · 首轮内测 Demo

原生 Swift / SwiftUI iPhone 应用，最低编译目标 iOS 15，竖屏。游戏界面按需求使用英文。当前版本用于内部试玩，不是已上架版本。

本轮计时用途声明在 `App/PrivacyInfo.xcprivacy`：`systemUptime` 用于生成预算和防重复操作的耗时计算，采用 `35F9.1` 理由，依据 [Apple 的 Required Reason API 文档](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype)。正式版仍需按最终 SDK 和真实数据处理重新核对。

## 直接运行

1. 用 Xcode 打开 `Capydoku.xcodeproj`。
2. Scheme 选 `Capydoku`，设备选 `iPhone 17 Pro` 或 `iPhone 17e`，点击 Run。
3. 首次进入会走动态教学；需要跳关时，在 Settings → Developer tools 中输入关卡号。
4. 真机需在 Signing & Capabilities 选择自己的 Team，并修改 Bundle Identifier（如果现有名称不能用于签名）。本次使用电脑已有开发签名完成了 Release 设备构建；工程没有写入私人 Team ID，也没有提交商店。安装到具体设备仍需该设备被开发配置文件包含、解锁并允许调试。

工程无需安装第三方依赖、XcodeGen 或广告 SDK。最低系统版本是编译目标；实际回归系统和结果见 `Validation/demo-acceptance.md`。

## 第一次试玩建议

先完成教学，体验普通 X、双击和横纵滑动。分别试一次 Find 和 Hint（先 Close，再通过模拟奖励重新打开并 Apply）。故意选错三个不同位置后，选择 Revive → Run simulation。最后领取签到，关闭应用再进入，检查盘面和库存。

想快速看大棋盘或持续生成，在 Developer tools 输入 150 或 151。发现问题时选 Export issue report，把导出的 JSON 连同操作步骤保留给后续修复；无需手抄 seed。

界面预览：[首页](Docs/preview-home.png) · [游戏页](Docs/preview-game.png)。

## 已实现的范围

- 四条规则、单击普通 X／撤销、双击提交、横纵滑动、生命、分数、Combo、失败、反复复活、重开和下一关。
- Find 与 Hint 独立库存；Hint 先预览，Apply 才改变棋盘；模拟奖励成功／取消／失败／重复回调／到账中断。
- 根据 L1 棋盘选择目标的 9 步教学；首页、游戏页、设置、签到、胜负、奖励与调试页面。
- 原创矢量角色和图标、区域色板、操作反馈、程序合成临时音效／音乐、系统语音和震动独立开关。
- UTC 连续签到、7 天周期、奖励防重复、日期回拨保护。
- 保存完整对局快照、配置快照、库存、设置、签到、教学、尝试次数和奖励台账；校验、备份回退及迁移。
- 150 个原创关卡；151+ 在后台限时生成并校验，保留当前棋盘／seed／版本。151–180 连续三组已进行自动验证。
- 调试跳关、当前 seed／指纹／配置查看、临时参数调整和问题 JSON 导出。调试入口只出现在 Debug 构建。

Daily Challenge、Pattern Mode、排行榜和活动本轮没有入口。真实广告、分析、远程配置、推送等外部服务均未接入；实际广告接入仍按外部分工处理。

## 本轮临时规则

配置集中在 `Sources/CapydokuCore/DemoConfig.swift`，版本 `demo-2026-09-v2`。参数与整盘一起存档，不会在进行中变化。开发面板修改只影响下一次新开局，重新启动恢复默认配置。

| 参数 | Demo 初值／行为 | 原因与边界 |
|---|---|---|
| 生命 | 3；每次成功复活恢复 3 | 可重复复活，保留动物、两类标记与分数 |
| Find / Hint | 每个首次进入的关卡各 1 次 | 使用后重开或回到该关不补发；签到／奖励库存可跨关 |
| 分数 | 正确位置 100；连续正确每次额外增加 20 | 临时反馈数值，非参考产品已确认值 |
| Combo | 连续 2 / 3 / 4 次显示 Nice / Great / Excellent | 错误归零；道具找到也计入，之后可按正式基线调整 |
| Hint | 显示预览即扣 1；关闭不退款 | 不自动改盘；无可排除格不扣次 |
| 标记 | 普通 X 可撤销；红 X 是受保护的已判错位置 | 同一错误格重复提交不重复扣血 |
| 重开 | 原盘、分数归零、生命恢复、尝试 +1 | 剩余道具保持，不重新发放免费道具 |
| 签到 | 每日 1 Hint；连续第 7 日再加 1 Find | UTC；断签重计；设备时间可被人为前调，未接服务器校时 |
| 生成 | 默认 4 秒、150 个候选；硬上限 8 秒／500 候选 | 后台执行，失败保留原盘并提示重试，最大 10×10 |

包内关卡规模：L1–10 为 4×4，L11–50 为 6×6，L51–100 为 8×8，L101–150 为 10×10。后续每十关包含 2 Flow、1 Recovery 和末关 Hard，规模为 6／8／10。

**这些标签只描述临时节奏，没有完成正式难度校准。** 当前基础逻辑求解器可完整解出 35/150 关，其余关卡可能需要明确标为 “Contradiction check” 的反证提示。合法、唯一解不等于玩家体验已合格。详见关卡报告中的逐关指标。

## 验证与复现

```sh
swift test
python3 scripts/verify_levels.py
xcodebuild -project Capydoku.xcodeproj -scheme Capydoku \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO test
```

重新生产关卡（会更新关卡包和报告；修改后需要重新回归）：

```sh
swift run -c release CapydokuLevelTool --start 1 --count 150 --output .
swift run -c release CapydokuLevelTool --start 151 --count 30 --experimental --output .
```

新增 App 或 UITests 源文件后运行 `python3 scripts/generate_project.py` 更新工程。它是本仓库的确定性工程生成脚本；当前工程已生成，不需首次运行时手动执行。

## 目录与交付资料

| 路径 | 用途 |
|---|---|
| `App/` | 应用入口、页面、手势绘制、视听反馈、奖励适配边界 |
| `Sources/CapydokuCore/` | 与页面独立的规则、生成、提示、对局、存档和奖励逻辑 |
| `Sources/CapydokuLevelTool/` | 关卡批量生产与自动通关验证工具 |
| `Resources/levels.json` | 首轮 150 关，附答案、seed、版本及区域信息 |
| `Tests/` / `UITests/` | 核心测试和实际模拟器交互回归 |
| `Validation/levels-report.json` | 150 关逐关校验；46 个重点关自动通关与同盘恢复 |
| `Validation/experimental-levels-report.json` | 151–180 三组连续生成与自动通关结果 |
| `Validation/demo-acceptance.md` | 沿用 88 条原 Checklist 的本轮适用范围与实际结果 |
| `CHANGELOG.md` | 本轮修复和后续决定项 |

自动通关用于证明规则、提示和恢复正确，不代替你们的真实试玩、难度评价或真机长时间测试。正式资源替换、第三方接入、正式难度与跨产品比较、签名、商店资料和发布验收仍需继续完成。
