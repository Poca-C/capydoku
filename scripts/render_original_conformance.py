"""Render the repository's source-linked acceptance matrix without changing its evidence."""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
data = json.loads((ROOT / 'Validation/original-conformance.json').read_text())
sections = {'1': '参考基线', '2': '核心玩法与道具', '3': '关卡生成与验证',
            '4': '界面与视觉', '5': '音频', '6': '数据与分析',
            '7': '平台、SDK与存档', '8': '广告与商业化'}

def escape(value):
    return value.replace('|', '\\|').replace('\n', '<br>')

lines = ['# 原始需求逐项符合性记录', '',
         '本记录以原始 Word V1.3 正文及附图为依据。结论：**可内部试玩，部分符合；冻结参考、外部接入和上架尚未验收。** 后续报告和旧 Checklist 不覆盖原文。', '',
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
for item in data['priorityClientFollowUps']:
    lines.append(f"- **{item['id']} · {item['priority']} · {item['topic']}**：{item['finding']} {item['next']}")
for section, title in sections.items():
    lines += ['', f'## {section} · {title}', '', '| ID／原文索引 | 要求与状态 | 实现和证据／仍缺内容 |', '|---|---|---|']
    for row in data['rows']:
        if row['section'] != section:
            continue
        paragraphs = ' '.join(f'[{number}]' for number in row['sourceParagraphs'])
        links = ' · '.join(f'[{Path(path).name}](../{path})' for path in row['evidence'])
        lines.append(f"| {row['id']}<br>{paragraphs} | {escape(row['title'])}<br>`{row['status']}` | {escape(row['implemented'])}<br>**缺口：**{escape(row['gap'])}<br>{links} |")
lines += ['', '本表与 [本轮验证记录](original-verification.json) 配合阅读；历史测试失败保留，仅明确标注的通过重验计入证据。', '']
(ROOT / 'Validation/original-conformance.md').write_text('\n'.join(lines))
