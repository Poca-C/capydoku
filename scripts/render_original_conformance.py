"""Render the repository's source-linked acceptance matrix without changing its evidence."""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
data = json.loads((ROOT / 'Validation/original-conformance.json').read_text())
current_verification = Path(data.get('currentVerification', 'Validation/original-verification.json')).name
phone_build = data.get('latestVerifiedPhoneBuild')
phone_evidence = f"，手机最近安装证据为**{phone_build}**" if phone_build else ''
sections = {'1': '参考基线', '2': '核心玩法与道具', '3': '关卡生成与验证',
            '4': '界面与视觉', '5': '音频', '6': '数据与分析',
            '7': '平台、SDK与存档', '8': '广告与商业化'}

def escape(value):
    return value.replace('|', '\\|').replace('\n', '<br>')

lines = ['# 原始需求逐项符合性记录', '',
         '本记录以原始 Word V1.3 正文及附图为依据。结论：**可内部试玩，部分符合；客户端仍有未实现项，冻结参考、外部接入和上架尚未验收。** 后续报告和旧 Checklist 不覆盖原文。', '',
         f"当前已验证本地构建：**{data.get('currentBuild', '见验证记录')}**{phone_evidence}。实际测试范围与结果见 [当前验证记录]({current_verification})；此前综合记录保留在 [历史验证记录](original-verification.json)。", '',
         f"原文校验值：`{data['source']['sha256']}`。原文[n]对应 [document.txt](../Reference/Original/document.txt) 的0-based正文块索引（含表格），不是页码。83行是实质要求分组，不是完成率。", '',
         '## 状态含义', '',
         '- `implemented`：已实现及检查代码，尚无完整当前构建证据。',
         '- `verified`：只验证本行明确描述的行为，仍须阅读缺口。',
         '- `awaiting_reference`：缺冻结参数、素材或样本。',
         '- `external_pending`：缺外部服务或发行条件，不免除客户端责任。',
         '- `partial`：实现、对接或验证仍有缺口。', '',
         '## 证据边界', '']
lines += ['- ' + item for item in data['evidenceLimitations']]
lines += ['', '## 后续处理项', '']
if data.get('currentStatusSummary'):
    lines += [data['currentStatusSummary'], '']
for item in data['priorityClientFollowUps']:
    lines.append(f"- **{item['id']} · {item['priority']} · {item['topic']}**：{item['finding']} {item['next']}")
rendered_ids = []
for section, title in sections.items():
    lines += ['', f'## {section} · {title}', '', '| ID／原文索引 | 要求与状态 | 实现和证据／仍缺内容 |', '|---|---|---|']
    for row in data['rows']:
        if row['section'].split('.')[0] != section:
            continue
        rendered_ids.append(row['id'])
        paragraphs = ' '.join(f'[{number}]' for number in row['sourceParagraphs'])
        links = ' · '.join(f'[{Path(path).name}](../{path})' for path in row['evidence'])
        lines.append(f"| {row['id']}<br>{paragraphs} | {escape(row['title'])}<br>`{row['status']}` | {escape(row['implemented'])}<br>**缺口：**{escape(row['gap'])}<br>{links} |")
assert len(rendered_ids) == len(data['rows']) == len(set(rendered_ids)), 'Every source requirement must appear once in the readable report.'
lines += ['', f'本表与 [当前验证记录]({current_verification}) 及 [历史综合验证记录](original-verification.json) 配合阅读；历史测试失败保留，仅明确标注的通过重验计入证据。', '']
(ROOT / 'Validation/original-conformance.md').write_text('\n'.join(lines))
