#!/usr/bin/env python3
"""Offline, backed-up battery recovery. Quit Status Trio before invoking."""
import argparse, collections, datetime, hashlib, json, math, os, pathlib, plistlib, shutil, subprocess, tempfile, time

HOME = pathlib.Path.home()
TARGET = HOME / 'Library/Application Support/StatusTrio/BatteryTelemetry'
OLD = HOME / '.Trash/Status Trio_2026-10-05_20-25-51'
ROOT = HOME / 'Library/Application Support/StatusTrioRecovery'
KEYS = ['battery.timeEstimator.samples.v1', 'battery.timeEstimator.profiles.v1']
HELPER = pathlib.Path(__file__).with_name('preferences.swift')

def prefs(operation, path):
    subprocess.run(['swift', str(HELPER), operation, str(path)], check=True)

def stopped():
    result = subprocess.run(['pgrep', '-x', 'StatusTrio'], capture_output=True)
    if result.returncode == 0:
        raise RuntimeError('Quit Status Trio before recovery/rollback')

def encode(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), allow_nan=False).encode()

def atomic(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix='.recovery-', dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as stream:
            stream.write(data); stream.flush(); os.fsync(stream.fileno())
        os.replace(name, path)
    finally:
        if os.path.exists(name): os.unlink(name)

def manifest(root):
    return [{'file': str(p.relative_to(root)), 'bytes': p.stat().st_size,
             'sha256': hashlib.sha256(p.read_bytes()).hexdigest()}
            for p in sorted(root.rglob('*')) if p.is_file()]

def records(paths):
    lines, malformed = set(), []
    for path in paths:
        if not path.exists(): continue
        for number, line in enumerate(path.read_bytes().splitlines(), 1):
            try:
                value = json.loads(line)
                if not isinstance(value, dict) or not isinstance(value.get('recordedAt'), str):
                    raise ValueError('missing recordedAt')
                datetime.datetime.fromisoformat(value['recordedAt'].replace('Z', '+00:00'))
                lines.add(line)
            except (ValueError, TypeError, UnicodeError) as error:
                malformed.append({'file': str(path), 'line': number,
                                  'rawHex': line.hex(), 'error': str(error)})
    ordered = sorted(lines, key=lambda line: (json.loads(line)['recordedAt'], line))
    counts = collections.Counter(json.loads(line)['recordedAt'] for line in ordered)
    return ordered, malformed, sum(n - 1 for n in counts.values() if n > 1)

def recover():
    stopped()
    folder = ROOT / datetime.datetime.now().strftime('recovery-%Y%m%d-%H%M%S-%f')
    folder.mkdir(parents=True)
    if TARGET.exists(): shutil.copytree(TARGET, folder / 'current-logs')
    shutil.copytree(OLD / 'StatusTrio/BatteryTelemetry', folder / 'old-logs')
    shutil.copy2(OLD / 'com.lingsmbp.StatusTrio.plist', folder / 'old-full.plist')
    prefs('export', folder / 'current-full.plist')
    plist_path = HOME / 'Library/Preferences/com.lingsmbp.StatusTrio.plist'
    if plist_path.exists(): shutil.copy2(plist_path, folder / 'current-on-disk.plist')
    atomic(folder / 'backup-manifest.json', encode(manifest(folder)))
    current = plistlib.loads((folder / 'current-full.plist').read_bytes())
    old = plistlib.loads((folder / 'old-full.plist').read_bytes())
    report = {'backup': str(folder), 'createdAt': datetime.datetime.now().isoformat(), 'logs': []}
    dates = sorted({p.name for base in [folder / 'current-logs', folder / 'old-logs'] for p in base.glob('*.jsonl')})
    quarantine = []
    for name in dates:
        lines, bad, conflicts = records([folder / 'old-logs' / name, folder / 'current-logs' / name])
        quarantine.extend(bad)
        data = b'\n'.join(lines) + (b'\n' if lines else b'')
        atomic(folder / 'merged-logs' / name, data)
        report['logs'].append({'file': name, 'validRecords': len(lines), 'malformed': len(bad), 'sameTimestampVariants': conflicts})
    atomic(folder / 'quarantined-lines.json', encode(quarantine))
    # Use time/measurement identity (excluding segment) to make reruns idempotent.
    now = time.time() - 978307200
    merged, seen, segment = [], set(), 0
    rejected = 0
    for source in [old, current]:
        previous = None
        samples = json.loads(source.get(KEYS[0], b'[]'))
        for sample in sorted(samples, key=lambda item: item.get('date', -1)):
            date, percent = sample.get('date'), sample.get('percentage')
            if not isinstance(date, (float, int)) or not math.isfinite(date) or not now - 60 * 86400 <= date <= now or not isinstance(percent, (float, int)) or not math.isfinite(percent) or not 0 <= percent <= 100:
                rejected += 1; continue
            identity = encode({k: v for k, v in sample.items() if k not in ['segment', 'boundaryReason']})
            if identity in seen: continue
            seen.add(identity)
            state = (sample.get('segment', 0), sample.get('charging'), sample.get('connectedToPower', sample.get('charging')), sample.get('target'))
            if previous is None or state != previous[0] or date - previous[1] > 180:
                segment += 1
            copy = dict(sample); copy['segment'] = segment
            merged.append(copy); previous = (state, date)
        segment += 1
    merged.sort(key=lambda item: (item['date'], item['segment']))
    merged = merged[-25000:]
    profiles = []
    profile_seen = set()
    for source in [old, current]:
        for profile in json.loads(source.get(KEYS[1], b'{"profiles":[]}')).get('profiles', []):
            identity = encode(profile)
            if identity not in profile_seen:
                profiles.append(profile); profile_seen.add(identity)
    candidate = {KEYS[0]: encode(merged), KEYS[1]: encode({'profiles': profiles})}
    atomic(folder / 'candidate.plist', plistlib.dumps(candidate))
    for path in (folder / 'merged-logs').glob('*.jsonl'): atomic(TARGET / path.name, path.read_bytes())
    prefs('restore', folder / 'candidate.plist')
    prefs('export', folder / 'after-full.plist')
    after = plistlib.loads((folder / 'after-full.plist').read_bytes())
    unchanged = {k: v for k, v in current.items() if k not in KEYS} == {k: v for k, v in after.items() if k not in KEYS}
    if not unchanged or any(after.get(k) != candidate[k] for k in KEYS):
        raise RuntimeError(f'Preference verification failed; restore from {folder}')
    report.update({'otherSettingsUnchanged': unchanged, 'samples': len(merged), 'rejectedSamples': rejected,
                   'profiles': len(profiles), 'chargeProfiles': sum(p['direction'] == 'charging' for p in profiles),
                   'dischargeProfiles': sum(p['direction'] == 'discharging' for p in profiles),
                   'sampleDateRange': [merged[0]['date'], merged[-1]['date']] if merged else []})
    atomic(folder / 'report.json', encode(report))
    print(str(folder)); print(json.dumps(report, ensure_ascii=False))

def rollback(folder):
    stopped()
    save = ROOT / datetime.datetime.now().strftime('pre-rollback-%Y%m%d-%H%M%S-%f')
    save.mkdir(parents=True)
    if TARGET.exists(): shutil.copytree(TARGET, save / 'logs')
    prefs('export', save / 'preferences.plist')
    # Remove only daily files introduced by this recovery; preserve a full copy first.
    before = folder / 'current-logs'
    recovered = folder / 'merged-logs'
    for path in recovered.glob('*.jsonl'):
        original = before / path.name
        if original.exists(): atomic(TARGET / path.name, original.read_bytes())
        elif (TARGET / path.name).exists(): (TARGET / path.name).unlink()
    prefs('restore', folder / 'current-full.plist')
    print(f'Rolled back; post-recovery records saved in {save}')

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--rollback', type=pathlib.Path)
    args = parser.parse_args()
    rollback(args.rollback) if args.rollback else recover()
