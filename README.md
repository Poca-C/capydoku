# Capydoku · 原文对齐 Demo

原生 Swift / SwiftUI iPhone 应用，英文界面、竖屏，最低编译目标 iOS 15。当前版本 **0.2.1（4）**，可内部试玩，尚未达到正式验收或上架状态。

## 唯一需求基准

以工作区原始《卡皮巴拉主题（Capydoku）区域逻辑小游戏需求说明 V1.3》的正文和内嵌截图为准。`Reference/Original/document.json` 保存源文件校验值与提取结果。后续报告及88条 Checklist只作核查，不能覆盖原文。0.1.x 的功能测试通过记录不证明符合原文。

当前逐章对照与未完成项见 `Validation/original-conformance.md`；本轮实际测试记录见 `Validation/original-verification.json`。

## 运行和试玩

1. 用 Xcode 打开 `Capydoku.xcodeproj`，选择 `Capydoku` 和 iPhone 17 Pro / iPhone 17e，Run。
2. 正常首次启动展示 Welcome、可点击的内部演示条款及同意流程，再按系统状态依次处理通知和 Tracking；正式条款与隐私链接待发布方提供。
3. 从 Level 1 进入动态教学。体验单击 X / 撤销、横纵滑动、双击、Find 和 Hint。Hint 关闭不改盘，Apply 才写入 X。
4. 故意选错至失败，点击 Play On 直接运行**明确标注的模拟广告**，无需第二次确认；复活保留原局。签到后关闭并重进验证状态。
5. Debug 构建中，**长按 Settings 标题**进入开发面板，可跳关、选择模拟奖励结果、查看 seed / 配置和导出定位信息。

当前截图：[首页](Docs/original-reference/01-home.png) · [游戏](Docs/original-reference/04-gameplay.png) · [提示](Docs/original-reference/05-hint.png) · [设置](Docs/original-reference/02-settings.png) · [签到](Docs/original-reference/03-check-in.png)。

无需第三方依赖或真实广告 SDK。真机运行需自己的签名与可用设备。本轮仅模拟器测试；先前版本签名成功不算本版本真机通过。

## 本次纠正

- 按原文重建首页、棋盘、三个规则卡、四个横向设置开关、签到日历、提示遮罩及胜负弹层；角色保持卡皮巴拉特征，使用参考风格的原创图像。
- 红色错误 X 也能单击撤销和再次双击提交；只防同次触摸重复送达，不永久锁住错误格。找到动物不自动打 X。
- 教学目标来自当前棋盘的逻辑证明，不读取隐藏答案选教学位置。
- 未完成教学时重开会从头教学；返回首页或重启恢复保留当前步骤。教学已完成后重开不重复教学。
- 道具、免费奖励、免费复活、失败文案和插页条件使用逐关配置接口；广告模拟保留完整奖励台账、防重与中断恢复。L10 首次通关按配置经过插页，再展示 A New Challenge。
- 广告超时仅针对等待加载；已展示广告等待最终回调，长视频不会被加载计时误取消。后台收到提示奖励后，同进程回前台显示一次预览；冷启动仍按原文补库存。
- 原先合成的音乐、系统配音与额外音效已撤除。音频只能从参考资源清单导入；**当前没有原音频，保持静音，不能视为音频验收通过**。震动开关独立。
- 音频接口区分页面、弹层、输入锁、广告及后台，支持显式播放映射、循环点、淡入淡出、连拍队列与停止策略。音频配置缺项或资源不合法时拒绝播放，不替用户猜原版参数。
- 包内关卡不再写入玩家存档，存档保存关卡引用和玩家状态；151+ 实验棋盘另存不可变缓存。保留旧关卡包以恢复旧版本的进行中对局。
- 正常操作串行异步保存；奖励、签到和进入后台前保证保存顺序。小型同意/通关记录也加入校验及备份。
- 最小分析事件在同意后进入本地持久队列；没有接入外部分析平台或生成看板。

## 关卡证据与限制

`Resources/levels.json` 是重新生成的150关。每关经过100个候选、求解、难度筛选、相似度拒绝和选优；失败批次另存拒绝原因。本次共筛选19,500个候选，含15个被拒绝批次。

150关及151–180三组实验共180关均通过独立唯一解与区域连通检查；180种不同答案排列、180种不同区域结构，严格拒绝完全重复，没有小棋盘例外。150关全部通过共享逻辑推完与按生成元数据重建。难关按推理指标筛选，可有紧凑难关，不能用尺寸替代难度。

**以上不等于已对齐 Pawdoku 的难度体验。** 当前 Profile 数值、预计时长与失败压力为明确标注的本地估计。冻结版难度采样与跨产品对比语料尚未提供。证据见 `Validation/original-generation/summary.json`。

151+ 在后台有预算地生成，保存同盘、seed 与生成器版本；失败保留旧盘并允许重新尝试。这仍是获准的 Demo 实验方案。

## 尚待资料或接入

- Pawdoku 冻结版本、逐关道具/广告/失败流程、难度采样与完整录屏。`Reference/gameplay-template.json` 保持空值，不能把示例数值当冻结配置。导入说明见 `Reference/gameplay-import.md`。
- 开局免费广告的精确出现顺序、特殊重开换盘行为、分数/Combo、签到奖励/统一时区与服务器校时，仍需参考资料确认。要求重开换盘的导入配置目前会明确报未支持并保留原局，不会静默用同盘替代。
- 原音频、具体触发映射/淡入淡出/循环点与听感验收；正式法律链接、反馈收件人及发布素材。
- 真实广告 SDK、分析/崩溃/远程配置/推送服务与后台看板；插页事件字段和复活后结果统计口径需完成合同映射。
- 真机、最低系统运行、长时间试玩、正式签名和 App Store 发布验收。

Daily Challenge 仅保留锁定入口；Pattern Mode、Profile、排行榜和活动未开放。原文无账号、充值转账或云存档系统，本工程没有新增这些系统。

## 验证与复现

```sh
swift test
python3 scripts/verify_levels.py
python3 -m unittest discover -s scripts -p 'test_import_reference_gameplay.py'
xcodebuild -project Capydoku.xcodeproj -scheme Capydoku \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO test
```

只检查现有关卡，避免误覆盖生产包：

```sh
swift run -c release CapydokuLevelTool --audit-production --catalog Resources/levels.json --output .
swift run -c release CapydokuLevelTool --audit-existing --catalog Resources/levels.json --output .
```

重新生成是显式生产操作。实验生成必须带150关历史，跨产品语料提供后另传 `--similarity-corpus`：

```sh
swift run -c release CapydokuLevelTool --start 1 --count 150 --output .
swift run -c release CapydokuLevelTool --start 151 --count 30 --experimental \
  --history-levels Resources/levels.json --output /tmp/capydoku-experimental
```

新增 Swift 或资源文件后运行 `python3 scripts/generate_project.py`。工程已生成，首次打开无需运行脚本。

目录：`App/` 页面和应用流程，`Sources/CapydokuCore/` 规则/生成/存档，`Reference/` 原文与参考导入材料，`Validation/` 验证证据，`AppTests/` / `Tests/` / `UITests/` 分层测试。临时配置版本为 `original-demo-unverified-v3`，新局生效，进行中对局保持其配置快照。
