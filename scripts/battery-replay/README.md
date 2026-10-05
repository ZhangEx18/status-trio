# Battery chronological replay

Run from the repository root with Python 3 and the installed Swift compiler:

```bash
python3 scripts/battery-replay/replay.py \
  --logs "$HOME/Library/Application Support/StatusTrio/BatteryTelemetry" \
  --output "$HOME/Library/Application Support/StatusTrio/BatteryReplay/latest"
python3 scripts/battery-replay/test_replay.py
```

`--logs` may be repeated to merge multiple directories. Identical JSON records are deduplicated; conflicting records at the same timestamp are reported and only the first is replayed because the estimator requires increasing timestamps. Invalid lines are recorded in `report.json`. The script never modifies input logs or live preferences and rejects output paths within the repository.

The default baseline is commit `38212e6`; `--baseline <commit>` changes it. Each model is compiled separately from its real Swift sources in a temporary directory. The candidate uses current working-tree sources. Both start cold, retain the production 95%/5% bidirectional activation requirement, and only capture profiles after observed completion, following the monitor's capture-key transitions. This measures the current estimator, not a Python approximation or a re-score of logged predictions.

Outputs are `baseline.jsonl`, `candidate.jsonl`, `excluded-same-timestamp.jsonl`, `report.json`, and `report.md`. The JSON report includes deduplicated short probes, paired full ETA metrics, unpaired coverage, per-session metrics, system ETA metrics, forecast jumps, source switches, source hashes, and every group exceeding the 5% MAE/P90 regression threshold. Error units are minutes; MAPE is percent. Empty groups are N/A.

Full ETA pairs must share the observation timestamp and actual target endpoint. The load grouping uses baseline state so a state-machine fix cannot improve a group merely by moving rows to another label. System full ETA targets 100%/0% and is reported separately from reserve ETA. A continuous session ends at mode/target/segment changes, nonmonotonic capacity, excessive capacity jumps, or a gap above 180 seconds. Older logs lack sleep boundary markers; this replay cannot validate unrecorded sleeps. Repeated readings remain chronological updates, but completed probes are deduplicated. Observation counts do not represent independent sessions.

The script reports regressions without exiting unsuccessfully: inspect `blockers` and coverage in `report.json` before acceptance. No coefficient tuning or modification of stored profiles occurs during replay.
