import json
import pathlib
import tempfile
import unittest

from replay import evaluate, load_logs, probes


class ReplayTests(unittest.TestCase):
    def test_log_merge_keeps_conflicts_but_deduplicates_identical_records(self):
        row = {"recordedAt": "2026-10-01T01:00:00Z", "percentage": 80,
               "charging": False, "connectedToPower": False}
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory)
            (path / "a.jsonl").write_text(json.dumps(row) + "\n" + json.dumps(row) + "\ninvalid\n")
            (path / "b.jsonl").write_text(json.dumps({**row, "percentage": 79}) + "\n")
            records, invalid, conflicts = load_logs([path])
            self.assertEqual(len(records), 1)
            self.assertEqual(len(conflicts), 1)
            self.assertEqual(len(invalid), 1)

    def test_repeated_probe_diagnostics_count_once(self):
        prediction = {"completedProbeStartedAt": 100, "completedProbeCrossedAt": 220,
                      "completedProbeFromPercent": 80, "completedProbeTargetPercent": 78,
                      "completedProbeActualMinutes": 2, "completedProbePredictedMinutes": 3}
        self.assertEqual(len(probes([{"mode": "discharging"}] * 4, [prediction] * 4)), 1)

    def test_full_eta_does_not_score_across_gap_or_compare_different_reserves(self):
        records = [{"timestamp": t, "percentage": p, "mode": "discharging", "target": 0,
                    "system": None} for t, p in [(100, 12), (160, 10), (1000, 5)]]
        baseline = [{"segment": 0, "minutes": 2, "reservePercent": 10},
                    {"segment": 0, "minutes": 1, "reservePercent": 10}, {"segment": 1}]
        candidate = [{"segment": 0, "minutes": 2, "reservePercent": 5},
                     {"segment": 0, "minutes": 1, "reservePercent": 5}, {"segment": 1}]
        report = evaluate(records, baseline, candidate)
        self.assertEqual(report["fullETA"]["discharging/all"]["baseline"]["n"], 1)
        self.assertEqual(report["fullETA"]["discharging/all"]["candidate"]["n"], 0)
        self.assertEqual(report["fullETAMatched"], {})
        self.assertEqual(report["blockers"], [])


if __name__ == "__main__":
    unittest.main()
