# 难度采样与 Profile 冻结

用途：补齐原文第 3 章前 150 关的真实难度依据。配套 [空白采样模板](difficulty-sampling-template.json) 是取证表，**不能直接作为 `--profiles` 输入**。未知量留 `null`，空记录不代表零次失败或零次提示。

| 字段组 | 需要填写 |
|---|---|
| sampling | 采样批次、日期、规则版本，覆盖 Capydoku L1–150 |
| referenceProducts | 原文正式基线为 **Pawdoku**；Meowdoku 目前只作辅助观察，替代基线须另行确认 |
| evidence | 来源、版本、证据文件编号和 SHA-256；所有统计可回查证据 |
| levelMappings | 为每关建立映射，可引用参考区间；记录棋盘尺寸、区域数、角色及证据编号 |
| independentPlayerSamples | 不同玩家匿名编号、熟练度、每次尝试的有效时长、提示、错误、失败及完成情况 |
| engineMeasurementCalibration | 单列机器规则层级、排除链、步数、估时及与玩家数据的校准依据 |
| profileCatalogPreparation | 样本量规则、汇总/异常值规则、目标区间、版本及 10%–15% 容差 |
| manualFreezeReview | 逐关覆盖、证据 hash、校准、Band 与容差复核，记录评审者和冻结决定 |

1. **先定采样口径。** 同一关允许重复尝试，但不能当成不同玩家；有效解题时间剔除后台、暂停及广告，另记剔除秒数。失败样本保留，不能只统计通关者。预先约定每关或参考区间所需独立样本数；不足则保持未验证。
2. **填取证表，再填现有 Catalog。** 先导出当前配置作为字段骨架；逐关按证据填写 `referenceLevelRange`、各 `…Target`。来源版本、采样日期、证据清单 hash 分别填入 `provenance` 的 `referenceVersion`、`sampledAt`、`referenceChecksum`。机器的规则层级、排除链、估时和停滞判定，不能冒充人的推理深度、真实时长或“必须试探”。当前过滤使用机器指标，真实玩家值必须先建立并复核映射，不能直接照抄到目标区间。严禁导入参考游戏的区域地图、答案坐标、开局或突破点数据。

```sh
swift run CapydokuLevelTool --export-profiles --start 1 --count 150 --output Validation/reference-candidate
swift run CapydokuLevelTool --profiles Validation/reference-candidate/difficulty-profiles.json --start 1 --count 150 --output Validation/reference-candidate/run
```

3. **双人复核后冻结。** 以上命令沿用 `DifficultyProfileCatalog` 和现有生成器，输出到独立候选目录。查看 `run/Validation/profile-import-report.json` 及逐关过滤报告；核对 L10/L20…Hard、Hard 后恢复、前 20 关节奏。10%–15% 须相对经采样及校准的参考值，且不得跨 Band；这些结论需人工冻结，不能靠扩大区间让生成通过。未完成前保留 `unverified_local_demo`；完整来源字段也只说明证据元数据齐全，**不等于难度已校准，`frozenReferenceVerified` 仍不能视为通过**。审批完成的 Catalog、证据 hash 和评审记录一同归档，再决定是否替换正式关卡包。
