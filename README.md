# Capydoku

卡皮巴拉主题的 iOS 区域逻辑益智游戏，使用 Swift / SwiftUI 开发，面向 iPhone 竖屏。默认简体中文，支持切换 English。

当前为 **0.2.68（71）内测 Demo**，尚未完成正式验收与上架。

## 快速运行

1. 仓库已公开，可直接克隆或拉取最新代码，无需邀请即可查看与下载。
2. 用 Xcode 打开 `Capydoku.xcodeproj`，选择 **Capydoku** scheme 和 iPhone 模拟器，点击 **Run**。工程已生成，无需安装第三方依赖；当前验证环境为 Xcode 26.6，最低编译目标为 iOS 15。
3. 真机运行时，在 Xcode 登录自己的 Apple 账号，在 **Signing & Capabilities** 选择自己的 Personal Team 和可签名的唯一 Bundle Identifier。连接并信任 iPhone，按提示开启开发者模式后运行；个人签名修改请保留在本地。

## 试玩内容

- 核心棋盘操作、教学、道具、生命、分数、Combo、胜负流程与复活。
- 首页、设置、签到、本地存档，以及 150 关和后续本地生成实验。
- 已包含 **9 个试听音频及播放配置**，默认 Debug 运行即可听到音乐、操作音效和 Combo 语音，无需另拷文件。正式构建与 Archive 仍使用独立音频配置，不包含这批试听资源。
- 广告使用明确标注的模拟流程。Daily Challenge、Pattern Mode、排行榜与活动暂未开放。

从第 1 关进入教学；Debug 下长按“设置”标题可进入开发面板，跳关、模拟奖励或导出定位信息。

## 项目文档

- [原始需求](Reference/Original/document.txt)：需求基准；后续报告与 Checklist 不覆盖原文。
- [验收进度与待办](Validation/original-conformance.md)：当前实现范围、证据与剩余问题；[原始 88 条 Checklist](Validation/checklist-source.json) 保留核查基准。
- [完整更新日志](CHANGELOG.md)：各版本改动与验证细节。
- [音频协作验证](Validation/github-0266-shared-audio.json)：干净克隆、资源打包和实际播放测试记录。

协作修改请从最新默认分支建立各自分支，review 后合并。仓库保留开发录屏，首次克隆可能较慢。

<details>
<summary>开发验证与目录说明</summary>

```sh
swift test
python3 scripts/verify_levels.py
python3 -m unittest discover -s scripts -p 'test_import_reference_gameplay.py'
xcodebuild -project Capydoku.xcodeproj -scheme Capydoku \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=YES test
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

</details>
