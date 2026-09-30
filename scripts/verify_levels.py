"""Independent row-by-row enumerator for the checked-in Swift-generated level pack."""
import hashlib
import json
from pathlib import Path

root = Path(__file__).resolve().parents[1]
data = (root / 'Resources/levels.json').read_bytes()
puzzles = json.loads(data)
records = []
geometries = set()
assert [p['id'] for p in puzzles] == list(range(1, 151))
for p in puzzles:
    n, regions = p['size'], p['regions']
    assert n in (4, 6, 8, 10) and len(regions) == n * n
    assert set(regions) == set(range(n))
    canonical, labels = [], {}
    for label in regions:
        labels.setdefault(label, len(labels))
        canonical.append(labels[label])
    key = (n, tuple(canonical))
    assert key not in geometries, f"Repeated geometry at {p['id']}"
    geometries.add(key)
    for region in range(n):
        cells = {i for i, value in enumerate(regions) if value == region}
        visited, frontier = set(), [next(iter(cells))]
        while frontier:
            cell = frontier.pop()
            if cell in visited:
                continue
            visited.add(cell)
            r, c = divmod(cell, n)
            for rr, cc in ((r-1, c), (r+1, c), (r, c-1), (r, c+1)):
                if 0 <= rr < n and 0 <= cc < n and rr*n+cc in cells:
                    if rr*n+cc not in visited:
                        frontier.append(rr*n+cc)
        assert visited == cells, f"Disconnected region at {p['id']}"
    answers = []
    def enumerate_rows(chosen, columns, used_regions):
        if len(answers) >= 2:
            return
        row = len(chosen)
        if row == n:
            answers.append([r*n+c for r, c in enumerate(chosen)])
            return
        for col in range(n):
            region = regions[row*n+col]
            if col in columns or region in used_regions:
                continue
            if chosen and abs(chosen[-1] - col) <= 1:
                continue
            enumerate_rows(chosen+[col], columns | {col}, used_regions | {region})
    enumerate_rows([], set(), set())
    assert len(answers) == 1 and answers[0] == sorted(p['solution']), f"Solution mismatch at {p['id']}"
    records.append({'level': p['id'], 'valid': True, 'solutionCount': 1, 'connected': True})
report = {
    'method': 'Independent Python row-order exhaustive solver; no Swift solver calls.',
    'levelPackSHA256': hashlib.sha256(data).hexdigest(),
    'allValid': True, 'count': len(records), 'distinctGeometries': len(geometries),
    'levels': records
}
(root / 'Validation/independent-validation.json').write_text(json.dumps(report, indent=2) + '\n')
print(f"PASS: {len(records)}/150 valid, connected, unique-solution boards; {len(geometries)} distinct geometries.")
