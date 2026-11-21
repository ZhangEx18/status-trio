import json
import pathlib
import tempfile
import unittest

from replay import _is_material_regression, evaluate, horizon10, load_logs, probes


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

    def test_ten_percent_horizon_uses_same_crossing_and_pairs_models(self):
        records = [
            {"timestamp": 0, "percentage": 80, "mode": "discharging", "target": 0},
            {"timestamp": 60, "percentage": 76, "mode": "discharging", "target": 0},
            {"timestamp": 120, "percentage": 72, "mode": "discharging", "target": 0},
            {"timestamp": 180, "percentage": 70, "mode": "discharging", "target": 0},
        ]
        baseline = [
            {"minutes": 30, "reservePercent": 5},
            {"minutes": 26, "reservePercent": 5},
            {"minutes": 23, "reservePercent": 5},
            {"minutes": 20, "reservePercent": 5},
        ]
        candidate = [
            {"minutes": 30, "reservePercent": 5},
            {"minutes": 27, "reservePercent": 5},
            {"minutes": 24, "reservePercent": 5},
            {"minutes": 23, "reservePercent": 5},
        ]

        report, matched, counts = horizon10(
            records, {"baseline": baseline, "candidate": candidate},
            [[0, 1, 2, 3]], {0, 1, 2, 3}
        )

        self.assertEqual(counts, {"baseline": 1, "candidate": 1, "matched": 1})
        self.assertEqual(report["discharging/all"]["baseline"]["mae"], 7)
        self.assertEqual(report["discharging/all"]["candidate"]["mae"], 4)
        self.assertEqual(matched["discharging/all"]["baseline"]["mae"], 7)
        self.assertEqual(matched["discharging/all"]["candidate"]["mae"], 4)

    def test_holdout_only_scores_records_inside_the_window(self):
        day = 24 * 60 * 60
        records = [
            {"timestamp": day, "percentage": 80, "mode": "discharging", "target": 0,
             "system": None},
            {"timestamp": 20 * day, "percentage": 76, "mode": "discharging", "target": 0,
             "system": None},
        ]
        predictions = [{"segment": 0, "minutes": 20, "reservePercent": 5} for _ in records]

        report = evaluate(records, predictions, predictions, holdout_days=14)

        self.assertEqual(report["evaluationWindow"]["evaluatedRecords"], 1)
        self.assertEqual(report["evaluationWindow"]["cutoff"], 6 * day)

    def test_material_regression_requires_both_relative_and_absolute_increase(self):
        self.assertFalse(_is_material_regression(8.95, 9.58))
        self.assertFalse(_is_material_regression(20, 20.8))
        self.assertTrue(_is_material_regression(10, 11.1))


if __name__ == "__main__":
    unittest.main()
