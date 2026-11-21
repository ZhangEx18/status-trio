# Battery chronological replay

Run from the repository root with Python 3 and the installed Swift compiler:

```bash
python3 scripts/battery-replay/replay.py \
  --logs "$HOME/Library/Application Support/StatusTrio/BatteryTelemetry" \
  --output "$HOME/Library/Application Support/StatusTrio/BatteryReplay/latest" \
  --holdout-days 14
python3 scripts/battery-replay/test_replay.py
```

`--logs` may be repeated to merge multiple directories. Identical JSON records are deduplicated; conflicting records at the same timestamp are reported and only the first is replayed because the estimator requires increasing timestamps. Invalid lines are recorded in `report.json`. The script never modifies input logs or live preferences and rejects output paths within the repository.

The default baseline is commit `57a7d30`; `--baseline <commit>` changes it. Each model is compiled separately from its real Swift sources in a temporary directory. The candidate uses current working-tree sources and, like `BatteryMonitor`, merges partial charge/discharge profiles whenever the estimator segment changes. Both start cold and retain the production 95%/5% bidirectional activation requirement before using learned profiles. This measures the current estimator, not a Python approximation or a re-score of logged predictions.

`--holdout-days` (default 14) filters scoring to the final N days. The replay still starts cold and trains chronologically, so this is an online holdout, not a frozen train/test split. Set it to `0` to score the whole history.

Outputs are `baseline.jsonl`, `candidate.jsonl`, `excluded-same-timestamp.jsonl`, `report.json`, and `report.md`. The JSON report includes deduplicated 2% short probes, matched full ETA, a 10% horizon metric, unpaired coverage, per-session metrics, system ETA metrics, forecast jumps, source switches, source hashes, and every group exceeding the 5% MAE/P90 regression threshold. The 10% horizon compares each model's ETA at a starting row with its ETA at the first row that confirms another ten percentage points of movement in the same continuous session; discharge pairs must use the same reserve. Error units are minutes; MAPE is percent. Empty groups are N/A.

The acceptance block requires a discharge 10% horizon MAE improvement of at least 15% and P90 improvement of at least 10%; charging 2% probes, charging full ETA, charging 10% horizon, and discharge full ETA must not materially regress; candidate charging and discharging coverage must both be nonzero; and no material regression blocker may remain. A material regression must exceed both 5% and one minute because the app displays whole-minute ETAs; this prevents a sub-minute integer-rounding change in one repeated session from rejecting an otherwise large improvement.

Full ETA pairs must share the observation timestamp and actual target endpoint. The load grouping uses baseline state so a state-machine fix cannot improve a group merely by moving rows to another label. System full ETA targets 100%/0% and is reported separately from reserve ETA. A continuous session ends at mode/target/segment changes, nonmonotonic capacity, excessive capacity jumps, or a gap above 180 seconds. Older logs lack sleep boundary markers; this replay cannot validate unrecorded sleeps. Repeated readings remain chronological updates, but completed probes are deduplicated. Observation counts do not represent independent sessions.

The script reports regressions without exiting unsuccessfully: inspect `blockers` and coverage in `report.json` before acceptance. No coefficient tuning or modification of stored profiles occurs during replay.
