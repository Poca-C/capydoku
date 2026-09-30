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
