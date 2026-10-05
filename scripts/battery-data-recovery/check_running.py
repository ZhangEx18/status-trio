#!/usr/bin/env python3
"""Bounded confirmation that restored history loads and live logging resumes."""
import datetime, json, pathlib, plistlib, subprocess, sys, time

folder = pathlib.Path(sys.argv[1])
name = datetime.datetime.now().strftime('%Y-%m-%d.jsonl')
log = pathlib.Path.home() / 'Library/Application Support/StatusTrio/BatteryTelemetry' / name
before = len((folder / 'merged-logs' / name).read_bytes().splitlines())
candidate = plistlib.loads((folder / 'candidate.plist').read_bytes())
deadline = time.monotonic() + 45
while time.monotonic() < deadline:
    lines = log.read_bytes().splitlines()
    if len(lines) > before: break
    time.sleep(1)
else: raise RuntimeError('Live telemetry did not resume within 45 seconds')
helper = pathlib.Path(__file__).with_name('preferences.swift')
subprocess.run(['swift', str(helper), 'export', str(folder / 'running-full.plist')], check=True)
values = plistlib.loads((folder / 'running-full.plist').read_bytes())
samples = json.loads(values['battery.timeEstimator.samples.v1'])
profiles = json.loads(values['battery.timeEstimator.profiles.v1'])['profiles']
assert len(samples) >= len(json.loads(candidate['battery.timeEstimator.samples.v1'])), 'Restored sample history unexpectedly shrank'
assert len(profiles) >= len(json.loads(candidate['battery.timeEstimator.profiles.v1'])['profiles']), 'Restored profiles unexpectedly disappeared'
pid = subprocess.check_output(['pgrep', '-x', 'StatusTrio']).decode().strip()
result = {'pid': pid, 'application': '/Applications/Status Trio.app',
          'recordsBeforeRestart': before, 'recordsAfterRestart': len(lines),
          'samplesAfterRestart': len(samples), 'profilesAfterRestart': len(profiles),
          'lastRecordedAt': json.loads(lines[-1])['recordedAt']}
(folder / 'restart-verification.json').write_text(json.dumps(result, indent=2))
print(json.dumps(result))
