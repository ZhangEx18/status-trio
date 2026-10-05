# Battery data recovery

These local tools restore the known October 5 backup without changing unrelated app preferences. Private backups and reports are stored outside the repository in `~/Library/Application Support/StatusTrioRecovery/`. They require macOS, Python 3, and Swift.

Quit Status Trio normally before running:

```bash
python3 scripts/battery-data-recovery/recover.py
```

The tool refuses to run while a `StatusTrio` process exists. It saves the current logs, the original archived logs, a complete CFPreferences export, and the original preference files before replacing anything. It prints the backup directory. Only the two `battery.timeEstimator.*.v1` keys are written through CFPreferences; the complete preference backup is not imported. JSONL lines retain their original bytes, duplicate lines are removed, and malformed lines are saved separately.

To compare two recovery passes, pass their printed backup directories:

```bash
python3 scripts/battery-data-recovery/verify.py FIRST_BACKUP SECOND_BACKUP
```

To roll back, quit Status Trio, then pass the **first** backup directory:

```bash
python3 scripts/battery-data-recovery/recover.py --rollback FIRST_BACKUP
```

Rollback saves current logs and preferences in a new `pre-rollback-*` directory before restoring the original daily files and two battery keys. Records added after recovery remain in that safety copy. Files from the archived source are never removed. If recovery fails after a replacement begins, use this same rollback command.

Run the isolated merge regression test with `python3 scripts/battery-data-recovery/test_recovery.py`. After opening the original app, run `python3 scripts/battery-data-recovery/check_running.py FIRST_BACKUP` to check that today's log grows and restored model state remains present. This check is bounded to 45 seconds. The recovery report does not certify old profiles as trusted; algorithm migration is a separate step.
