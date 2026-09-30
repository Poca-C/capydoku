"""Build the demo result matrix from the unchanged original 88-case checklist."""
from pathlib import Path
import json
from collections import Counter

root = Path(__file__).resolve().parents[1]
source = json.loads((root / 'Validation/checklist-source.json').read_text())
verification = json.loads((root / 'Validation/verification-summary.json').read_text())
P, PART, B, NA = '通过（Demo）', '部分通过／待补验', '待验', '本轮不适用'
results = {}
def set_cases(ids, status, evidence):
    for case in ids.split(): results[case] = (status, evidence)

set_cases('01-01 01-02', PART, '采用明确标注的 Demo 配置；正式参考版本、计分、道具节点和难度基线未冻结。')
set_cases('01-03', P, 'README、CHANGELOG 记录首轮边界；广告外部负责，其他服务未擅自视为正式取消。')
set_cases('02-01', PART, '两种模拟器可构建、安装和冷启动；设备Release开发签名构建通过，真机安装运行尚未验证。')
set_cases('02-02', PART, '本轮为编译内置默认配置＋对局配置快照，无远程配置；存档损坏有回退测试。')
set_cases('02-03', P, 'Debug 调试入口、测试专用存档目录、seed／版本；Release 隐藏调试入口和测试启动参数。')
set_cases('03-01 03-02', P, 'PuzzleEngineTests：非法、无解、多解、区域不连通、八邻接；150 关另有独立 Python 穷举复核。')
set_cases('03-03', PART, '150关提示安全、清空隐藏答案后输出一致；明确逻辑可解141关，其余9关保留标注反证。正式推理深度与难度基线待校准。')
set_cases('03-04', P, 'GameSessionTests、PersistenceTests 与模拟器恢复：动物、普通 X、红 X、状态和配置快照。')
set_cases('04-01', PART, '两种模拟器 4×4 和 10×10 操作；真机边缘触点和最大盘手感待测。')
set_cases('04-02 04-03 04-04 04-05', P, 'UI 回归实际执行单击撤销、双击一次提交、横纵滑动、已有标记与斜滑不改盘；核心测试防重复扣血。')
set_cases('04-06', P, '新增实际 UI 混合连击和划出棋盘测试：红 X 不重复扣血，已找到不重复加分，手指离开棋盘即终止本次标记；真机手感仍归16-01待验。')
set_cases('04-07', P, '提示与结束状态锁盘；AppModel集成测试验证设置／后台不能Apply、连续30次重复Apply／Hint不重复扣次或改盘，实际UI确认关闭提示和设置不改变盘面。')
set_cases('05-01 05-03', PART, 'Demo 显示、分数、低生命提示与保存一致；未声称等同正式冻结数值／表现。')
set_cases('05-02', P, '核心测试胜利后立即锁定、结束幂等；UI 完整找齐并进入下一关。')
set_cases('05-04 05-05', P, '同盘重开、已用道具不补发、尝试计数；核心测试两轮死亡／复活，UI 测复活保留盘面。')
set_cases('05-06', PART, '下一关、首页和继续可走通；Rank／击败比例没有正式定义，本轮未开放。')
set_cases('06-01', PART, '生成批次、seed、版本、逐关合法性／逻辑指标／耗时已报告；全阶段候选淘汰统计未做正式交付。')
set_cases('06-02', PART, '非法／非唯一／不连通拒绝已测试；正式难度和违规试探筛选仍待冻结。')
set_cases('06-03', PART, '包内150关经旋转、镜像及区域重命名审计为150个独立几何，无等价重复；正式相似度权重／阈值和跨产品比较待验。')
set_cases('06-04', PART, '固定 seed 可重建、快照同盘恢复已测；正式难度与相似度报告待补。')
set_cases('06-05', P, '候选数／时间预算明确终止；UI生成失败时保留当前已完成棋盘，可返回首页且强退恢复；测试注入与保存的有效配置已分开。')
set_cases('07-01 07-02 07-03 07-04', P, '核心和 UI：免费优先、库存独立、重开防刷、直接找一个、Hint 预览扣次／关闭／Apply／错误 X 与无提示处理。')
set_cases('07-05 07-06 07-07 07-08', P, '模拟边界＋应用集成测试：无回调5秒超时不发奖、迟到／重复回调不影响新弹窗、后台到账恢复一次、写盘失败可重试保存；复活保持盘面；真实SDK待验。')
set_cases('07-09', B, 'L1–20 四激励入口的正式节点／次数及 level_start_free 尚待基线，未用模拟流程冒充真实广告验收。')
set_cases('08-01', P, '包内L1实际UI走通；另8个seed经AppModel按动态目标逐步操作、每步存档恢复，目标及生命／分数正确；64个seed通过教学适配核心测试。')
set_cases('08-02', P, '9 步实际 UI 教学覆盖四规则、单击／撤销、横纵滑动、双击；非目标操作由教学状态拦截。')
set_cases('08-03', P, '实际UI在第4/6/8/9步强退恢复；AppModel逐步恢复整条教学及半途swipe；完成状态不重入。生成器教学候选门禁另有专测。')
set_cases('09-01 09-02', PART, '1–150 编号齐全、版本与 seed 可追踪、全量合法唯一连通；正式难度及跨产品相似度待验。')
set_cases('09-03', PART, '每十关节奏已配置；仍有9关需要反证提示，其中96关暂标Recovery，尚不能验为轻松恢复关，正式难度标签待校准。')
set_cases('09-04', PART, '前20＋全部Hard／Recovery共46关自动求解驱动通关及恢复通过；这不是46关人工试玩报告。')
set_cases('10-01', PART, 'UI 实际打通150→151；真机与正式数据架构验收待完成。')
set_cases('10-02 10-03', PART, '151–180三组按实际配置生成，结构／唯一解／时间／数量上限验证；正式长期难度与相似度门槛待定。')
set_cases('10-04', P, 'UI 在151标记后强退恢复36格布局和状态；核心保存完整棋盘／seed／版本，无网络依赖。')
set_cases('11-01 11-02', PART, 'Demo 可离线核心游玩，未集成外部 SDK 因而无通知／Tracking 请求；正式条款和隐私链接待接入。')
set_cases('11-03', P, '首页、当前关卡、返回、设置与签到入口已 UI 回归，无资料／头像功能。')
set_cases('11-04', P, '四开关独立保存；UI 切换后强退重启验证，代码分别控制对应声音／触感。')
set_cases('11-05', PART, '设置关闭、重开、Hint与奖励弹层可恢复；Feedback 采用内部诊断导出，正式反馈去向待定。')
set_cases('11-06', NA, '依本轮计划暂不开放 Daily Challenge、Pattern Mode、排行榜和活动，未放置假入口。')
set_cases('12-01 12-02 12-03 12-04', P, 'UTC 核心单测覆盖7日周期、断签、日期回拨与跨日；UI 领取／同日禁领／强退后库存和状态恢复。')
set_cases('13-01 13-02', P, 'UI 棋盘状态、设置、签到切后台与强退恢复；核心测试存档字段和每关免费次数不重复。')
set_cases('13-03 13-04 13-05 13-06', P, '核心＋应用集成：到账与重复、备份回退、双损坏回首页并保留原件、迁移；新增合法JSON中非法棋盘／配置拒绝；10×10共240次保存／全新实例恢复逐次一致。')
set_cases('13-07', P, '独立临时17e模拟器：150关＋非零道具／已签到测试fixture经应用读取重存，卸载重装后进度、库存、签到归零；设备已清理。真机和云备份不在该证据范围内。')
set_cases('14-01', PART, '原创代码绘制角色／图标／区域／弹层；已检查主要模拟器截图，正式资产待替换。')
set_cases('14-02', PART, '17 Pro／17e 安全区与主要界面已检查；按钮44pt，10×10单格约35–36pt，真机密集点击及全量长文仍需复核。')
set_cases('14-03', PART, '角色状态、按钮按压、棋盘反馈圈已实现，尊重减少动态效果；低性能真机和签到专用动效待评审。')
set_cases('14-04 14-05', PART, '临时合成音频、独立四开关；补系统中断／音频服务重启恢复并通过编译，UI测试静音。实际来电、听感／触感及正式音频表仍待真机验收。')
set_cases('15-01 15-02 15-03 15-04 15-05 15-06 15-07 15-08 15-09', B, '本轮未接实际外部服务。奖励协议与模拟器只验证游戏侧流程，不替代SDK、分析、远程配置、监控、推送验收。')
set_cases('16-01', PART, '两种模拟器执行端到端回归；真机签名、长时间真人试玩尚未完成。')
set_cases('16-02', B, '生成耗时已记录；正式启动／帧率／内存F7标准未定，不能据模拟器推断真机性能合格。')
set_cases('16-03 16-04', P, '回归结果、已修复问题和本文件状态逐项留存；未把自动通关记作人工试玩，也未把待验项勾为正式通过。')
set_cases('17-01 17-02 17-03 17-04', B, '尚未正式签名、打包提审或上架。无正式商店材料／SDK隐私声明／目标地区下载证据。')
set_cases('17-05', PART, '本轮代码、Xcode工程、关卡、工具、报告和构建说明齐全；正式版交付项继续待验。')

all_ids = [row[0] for module in source for row in module['cases']]
assert set(results) == set(all_ids) and len(all_ids) == 88
counts = Counter(status for status, _ in results.values())
lines = ['# Capydoku 首轮 Demo 验收记录', '',
         '依据原《Capydoku成品验收Checklist》88条逐项映射。原Word未修改。**“通过（Demo）”只表示本轮临时配置和指定测试层面通过，不代表正式版本已验收或已经上架。**', '',
         '## 可复核的构建和验证', '',
         f'- 版本：{verification["version"]}；Xcode：{verification["xcode"]}；模拟器系统：{verification["simulatorOS"]}。',
         f'- 核心自动测试：{verification["coreTests"]}。',
         f'- 应用集成自动测试：{verification.get("appIntegrationTests", "待汇总")}。',
         f'- iPhone 17 Pro：{verification["iPhone17Pro"]}。',
         f'- iPhone 17e：{verification["iPhone17e"]}。',
         f'- 设备构建：{verification["releaseDeviceBuild"]}。',
         f'- 本轮补验：{verification.get("hardeningSummary", "见逐项记录")}。',
         '- 包内150关由 Swift 校验器和独立 Python 行顺序穷举求解器分别验证：全部合法、唯一解、区域连通，150个不同几何指纹。',
         '- 前20关及全部Hard／Recovery共46关：自动求解驱动通关并保存／恢复；151–180三组共30关另行生成、验证、通关／恢复。该结果不代表人工难度评价。',
         f'- 实际真机：{verification["physicalDevice"]}。低版本系统运行、长时间真人试玩、外部SDK、正式难度和上架仍待验。', '',
         '证据：`verification-summary.json`、`levels-report.json`、`experimental-levels-report.json`、`independent-validation.json`，`hint-quality-audit.json`、`reinstall-audit.json`，以及 `Tests/`、`AppTests/`、`UITests/` 中的可复现测试。原始运行记录见 `Validation/test-runs/`（本机保留，不加入源代码版本）。', '',
         '## 状态统计', '', '| 状态 | 条数 |', '|---|---:|']
lines += [f'| {state} | {counts[state]} |' for state in [P, PART, B, NA]]
for module in source:
    lines += ['', f'## {module["module"]:02d} · {module["title"]}', '', '| 原编号 | 原验收内容 | 本轮结果 | 证据／边界 |', '|---|---|---|---|']
    for row in module['cases']:
        identifier, detail = row[:2]
        status, evidence = results[identifier]
        detail = detail.replace('\n', '<br>').replace('|', '／')
        lines.append(f'| {identifier} | {detail} | {status} | {evidence} |')
(root / 'Validation/demo-acceptance.md').write_text('\n'.join(lines) + '\n')
print(dict(counts))
