#!/usr/bin/env python3
"""Verify two recovery passes and monitor restarted application's telemetry."""
import collections, hashlib, json, pathlib, plistlib, sys

first, second = map(pathlib.Path, sys.argv[1:3])
left = plistlib.loads((first / 'candidate.plist').read_bytes())
right = plistlib.loads((second / 'candidate.plist').read_bytes())
assert left == right, 'Second recovery changed battery preference values'
for path in (first / 'merged-logs').glob('*.jsonl'):
    assert path.read_bytes() == (second / 'merged-logs' / path.name).read_bytes(), path
old = first / 'old-logs'
current = first / 'current-logs'
merged = first / 'merged-logs'
for base in [old, current]:
    for path in base.glob('*.jsonl'):
        assert set(path.read_bytes().splitlines()) <= set((merged / path.name).read_bytes().splitlines()), path
counts = collections.Counter()
for path in merged.glob('*.jsonl'):
    for line in path.read_bytes().splitlines():
        record = json.loads(line)
        counts['charging' if record.get('charging') else 'idle' if record.get('connectedToPower') else 'discharging'] += 1
report = {'idempotentLogs': True, 'idempotentPreferences': True,
          'oldAndCurrentRecordsPreserved': True, 'recordModes': dict(counts)}
(first / 'verification.json').write_text(json.dumps(report, indent=2))
print(json.dumps(report))
