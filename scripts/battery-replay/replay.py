#!/usr/bin/env python3
"""Read-only chronological battery replay. All private outputs go outside the repo."""
import argparse
import collections
import datetime as dt
import hashlib
import json
import math
import pathlib
import statistics
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
SOURCE_DIR = pathlib.Path("Sources/StatusTrioCore/Monitoring")
SOURCES = ["BatteryTimeEstimator.swift", "BatteryTimeProfile.swift",
           "BatteryTimeProfileCatalog.swift", "BatteryTimeProfileBuilder.swift",
           "BatteryDischargeStateMachine.swift", "BatteryChargingModel.swift",
           "BatteryLongTermBaseline.swift", "BatteryDataCleansing.swift",
           "BatterySampleContinuity.swift"]


def timestamp(value):
    if isinstance(value, (float, int)):
        # JSONEncoder default Date uses Apple's reference epoch.
        return float(value) + 978307200
    return dt.datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()


def load_logs(directories, counts=None):
    records, invalid, seen = [], [], set()
    raw_count = duplicate_count = 0
    for directory in directories:
        for path in sorted(directory.glob("*.jsonl")):
            for number, line in enumerate(path.read_text().splitlines(), 1):
                raw_count += 1
                try:
                    row = json.loads(line)
                    key = json.dumps(row, sort_keys=True, separators=(",", ":"))
                    if key in seen:
                        duplicate_count += 1
                        continue
                    seen.add(key)
                    t = timestamp(row["recordedAt"])
                    p = float(row["percentage"])
                    if not math.isfinite(p) or not 0 <= p <= 100:
                        raise ValueError("invalid percentage")
                    charging = bool(row["charging"])
                    connected = bool(row["connectedToPower"])
                    mode = "charging" if charging and connected else "idle" if connected else "discharging"
                    target = row.get("estimatorTargetPercent")
                    if mode == "discharging":
                        target = 0.0
                    elif mode == "charging" and target is None and row.get("chargeLimitKnown"):
                        target = row.get("chargeLimit")
                    elif mode == "idle":
                        target = None
                    system = row.get("systemChargeMinutes" if charging else "systemDischargeMinutes")
                    boundary_reason = row.get("boundaryReason") or row.get("estimatorBoundaryReason")
                    records.append({"timestamp": t, "percentage": p, "charging": charging,
                                    "connectedToPower": connected, "target": target,
                                    "system": system if isinstance(system, int) and system > 0 else None,
                                    "dirty": bool(boundary_reason) or bool(row.get("dirty")),
                                    "boundaryReason": boundary_reason,
                                    "mode": mode, "original": row})
                except (ValueError, TypeError, KeyError) as error:
                    invalid.append({"file": str(path), "line": number, "reason": str(error)})
    records.sort(key=lambda row: row["timestamp"])
    # Conflicting same-time rows are preserved in the manifest, but not replayed
    # twice: estimator requires strictly increasing dates.
    valid, conflicts = [], []
    for row in records:
        if valid and row["timestamp"] == valid[-1]["timestamp"]:
            conflicts.append(row)
        else:
            valid.append(row)
    if counts is not None:
        counts.update(rawLines=raw_count, identicalJSONDuplicates=duplicate_count,
                      validUniqueRecords=len(records), excludedSameTimestamp=len(conflicts),
                      invalidLines=len(invalid), replayedRecords=len(valid))
    return valid, invalid, conflicts


def compile_model(directory, revision=None):
    paths = []
    for name in SOURCES:
        relative = SOURCE_DIR / name
        data = subprocess.check_output(["git", "show", f"{revision}:{relative}"], cwd=ROOT) if revision else (ROOT / relative).read_bytes()
        destination = directory / name
        destination.write_bytes(data)
        paths.append(destination)
    main = directory / "main.swift"
    main.write_bytes((ROOT / "scripts/battery-replay/main.swift").read_bytes())
    executable = directory / "replay"
    flags = ["-D", "CANDIDATE"] if revision is None else []
    subprocess.run(["swiftc", "-O", *flags, *map(str, paths), str(main),
                    "-o", str(executable)], check=True)
    return executable


def run_model(executable, records, output):
    payload = "\n".join(json.dumps({k: v for k, v in row.items() if k not in ("original", "mode")}) for row in records)
    with output.open("w") as stream:
        subprocess.run([str(executable)], input=payload, text=True, stdout=stream, check=True)
    predictions = [json.loads(line) for line in output.read_text().splitlines()]
    if len(predictions) != len(records):
        raise RuntimeError("replay output count differs from input")
    return predictions


def metrics(pairs):
    if not pairs:
        return {"n": 0, "mae": None, "median": None, "mape": None, "p90": None}
    errors = sorted(abs(predicted - actual) for predicted, actual in pairs)
    ratios = [abs(predicted - actual) / actual * 100 for predicted, actual in pairs if actual > 0]
    return {"n": len(pairs), "mae": statistics.mean(errors), "median": statistics.median(errors),
            "mape": statistics.mean(ratios) if ratios else None,
            "p90": errors[max(0, math.ceil(len(errors) * .9) - 1)]}


def band(percentage):
    return "low" if percentage < 20 else "high" if percentage >= 80 else "middle"


def probes(records, predictions, cutoff=None):
    result = {}
    for record, prediction in zip(records, predictions):
        if cutoff is not None and record["timestamp"] < cutoff:
            continue
        required = [prediction.get(key) for key in ("completedProbeStartedAt", "completedProbeCrossedAt",
                    "completedProbeFromPercent", "completedProbeTargetPercent", "completedProbeActualMinutes")]
        if any(value is None for value in required):
            continue
        started, crossed, start, target, actual = required
        # Key includes direction and exact endpoints; repeated diagnostic rows collapse.
        if not 0 < abs(target - start) <= 2.000001 or actual <= 0:
            continue
        key = (record["mode"], started, crossed, start, target)
        result[key] = {"actual": actual, "predicted": prediction.get("completedProbePredictedMinutes"),
                       "baseline": prediction.get("completedProbeBaselineMinutes"),
                       "band": band(start), "load": prediction.get("dischargeState", "unknown")}
    return result


def sessions(records, baseline, candidate):
    groups, current = [], []
    for index, record in enumerate(records):
        if current:
            previous = records[current[-1]]
            delta = record["percentage"] - previous["percentage"]
            monotonic = delta >= 0 if record["mode"] == "charging" else delta <= 0
            continuous = (0 < record["timestamp"] - previous["timestamp"] <= 180
                          and record["mode"] == previous["mode"] and record["target"] == previous["target"]
                          and abs(delta) <= 4 and monotonic
                          and baseline[index].get("segment") == baseline[current[-1]].get("segment")
                          and candidate[index].get("segment") == candidate[current[-1]].get("segment"))
            if not continuous:
                groups.append(current)
                current = []
        current.append(index)
    if current:
        groups.append(current)
    return groups


def horizon10(records, predictions, groups, evaluated_indices):
    """Score the implied time to move ten percentage points in one session."""
    observations = {name: {} for name in ("baseline", "candidate")}
    for group in groups:
        if not group:
            continue
        mode = records[group[0]]["mode"]
        if mode == "idle":
            continue
        for position, index in enumerate(group):
            if index not in evaluated_indices:
                continue
            origin = records[index]
            if origin["target"] is None:
                continue
            threshold = origin["percentage"] + (10 if mode == "charging" else -10)
            if mode == "charging" and threshold > origin["target"] + 1e-9:
                continue
            crossed_at = next((
                other for other in group[position + 1:]
                if (records[other]["percentage"] >= threshold if mode == "charging"
                    else records[other]["percentage"] <= threshold)
            ), None)
            if crossed_at is None:
                continue
            before = records[crossed_at - 1]
            after = records[crossed_at]
            change = after["percentage"] - before["percentage"]
            crossing = after["timestamp"] if change == 0 else before["timestamp"] + (
                threshold - before["percentage"]
            ) / change * (after["timestamp"] - before["timestamp"])
            actual = (crossing - origin["timestamp"]) / 60
            if actual <= 0:
                continue
            for name, model in (("baseline", predictions["baseline"]),
                                ("candidate", predictions["candidate"])):
                current = model[index].get("minutes")
                crossed_prediction = model[crossed_at]
                later = crossed_prediction.get("minutes")
                if current is None or later is None:
                    continue
                if mode == "discharging" and (
                    model[index].get("reservePercent")
                    != crossed_prediction.get("reservePercent")
                ):
                    continue
                implied = current - later
                if not math.isfinite(implied):
                    continue
                observations[name][(index, crossed_at)] = {
                    "implied": implied, "actual": actual, "mode": mode,
                    "band": band(origin["percentage"])
                }

    def grouped(name):
        result = collections.defaultdict(list)
        for value in observations[name].values():
            result[f"{value['mode']}/all"].append((value["implied"], value["actual"]))
            result[f"{value['mode']}/{value['band']}"].append(
                (value["implied"], value["actual"])
            )
        return result

    all_report = {}
    for name in ("baseline", "candidate"):
        for key, pairs in grouped(name).items():
            all_report.setdefault(key, {})[name] = metrics(pairs)

    shared = observations["baseline"].keys() & observations["candidate"].keys()
    matched = collections.defaultdict(lambda: {"baseline": [], "candidate": []})
    for key in shared:
        base = observations["baseline"][key]
        candidate = observations["candidate"][key]
        for group in (f"{base['mode']}/all", f"{base['mode']}/{base['band']}"):
            matched[group]["baseline"].append((base["implied"], base["actual"]))
            matched[group]["candidate"].append((candidate["implied"], candidate["actual"]))
    matched_report = {
        key: {name: metrics(pairs) for name, pairs in values.items()}
        for key, values in matched.items()
    }
    return all_report, matched_report, {
        "baseline": len(observations["baseline"]),
        "candidate": len(observations["candidate"]),
        "matched": len(shared),
    }


def _is_material_regression(old, new, relative=0.05, absolute=1.0):
    return new is not None and old is not None and new > old * (1 + relative) \
        and new - old > absolute


def _regression_check(label, values, relative=0.05, absolute=1.0):
    old, new = values["baseline"], values["candidate"]
    available = old["n"] > 0 and new["n"] > 0
    passed = available and all(
        not _is_material_regression(old[metric], new[metric], relative, absolute)
        for metric in ("mae", "p90")
    )
    return {"name": label, "passed": passed, "baseline": old, "candidate": new,
            "rule": f"MAE and P90 must not exceed baseline by both {relative:.0%} "
                    f"and {absolute:g} minute"}


def _improvement_check(label, values, mae_improvement, p90_improvement):
    old, new = values["baseline"], values["candidate"]
    available = old["n"] > 0 and new["n"] > 0
    mae_ratio = 1 - new["mae"] / old["mae"] if available and old["mae"] else None
    p90_ratio = 1 - new["p90"] / old["p90"] if available and old["p90"] else None
    passed = (available and mae_ratio is not None and p90_ratio is not None
              and mae_ratio >= mae_improvement
              and p90_ratio >= p90_improvement)
    return {"name": label, "passed": passed, "baseline": old, "candidate": new,
            "maeImprovement": mae_ratio, "p90Improvement": p90_ratio,
            "rule": f"MAE improves at least {mae_improvement:.0%}; "
                    f"P90 improves at least {p90_improvement:.0%}"}


def evaluate(records, baseline, candidate, holdout_days=14):
    last_timestamp = records[-1]["timestamp"]
    cutoff = (last_timestamp - holdout_days * 24 * 60 * 60
              if holdout_days > 0 else None)
    evaluated_indices = {
        index for index, record in enumerate(records)
        if cutoff is None or record["timestamp"] >= cutoff
    }
    bp = probes(records, baseline, cutoff)
    cp = probes(records, candidate, cutoff)
    shared = bp.keys() & cp.keys()
    probe_report = {}
    for mode in ("charging", "discharging"):
        for level in ("all", "low", "middle", "high"):
            keys = [key for key in shared if key[0] == mode and (level == "all" or bp[key]["band"] == level)
                    and bp[key]["predicted"] is not None and cp[key]["predicted"] is not None]
            probe_report[f"{mode}/{level}"] = {
                "baseline": metrics([(bp[key]["predicted"], bp[key]["actual"]) for key in keys]),
                "candidate": metrics([(cp[key]["predicted"], bp[key]["actual"]) for key in keys])}
    full = collections.defaultdict(lambda: {"baseline": [], "candidate": [], "system": []})
    matched_full = collections.defaultdict(lambda: {"baseline": [], "candidate": []})
    details = []
    groups = sessions(records, baseline, candidate)
    for number, group in enumerate(groups):
        first = records[group[0]]
        mode = first["mode"]
        if mode == "idle" or first["target"] is None:
            continue
        paired = {}
        # Use estimator's actual reserve: do not score a 10% ETA against a 0% endpoint.
        for model_name, predictions in (("baseline", baseline), ("candidate", candidate)):
            scores = []
            for position, index in enumerate(group):
                if index not in evaluated_indices:
                    continue
                record, prediction = records[index], predictions[index]
                target = first["target"] if mode == "charging" else prediction.get("reservePercent")
                predicted = prediction.get("minutes")
                if target is None or predicted is None:
                    continue
                endpoint = next((other for other in group[position + 1:]
                    if (records[other]["percentage"] >= target if mode == "charging" else records[other]["percentage"] <= target)), None)
                if endpoint is None:
                    continue
                # Interpolate between the final two real observations, not probe estimates.
                before = records[endpoint - 1]
                after = records[endpoint]
                change = after["percentage"] - before["percentage"]
                crossed = after["timestamp"] if change == 0 else before["timestamp"] + (target - before["percentage"]) / change * (after["timestamp"] - before["timestamp"])
                actual = (crossed - record["timestamp"]) / 60
                if actual <= 0:
                    continue
                scores.append((predicted, actual))
                paired[(index, target, model_name)] = (predicted, actual)
                full[f"{mode}/{band(record['percentage'])}"][model_name].append((predicted, actual))
                full[f"{mode}/all"][model_name].append((predicted, actual))
                load = prediction.get("dischargeState", "unknown")
                full[f"{mode}/load:{load}"][model_name].append((predicted, actual))
            details.append({"session": number, "mode": mode, "start": first["timestamp"],
                            "end": records[group[-1]]["timestamp"], "model": model_name, **metrics(scores)})
        for index, target, name in list(paired):
            if name != "baseline" or (index, target, "candidate") not in paired:
                continue
            old, new = paired[(index, target, "baseline")], paired[(index, target, "candidate")]
            # Same timestamp, same actual endpoint, same load stratum (baseline's).
            keys = [f"{mode}/all", f"{mode}/{band(records[index]['percentage'])}",
                    f"{mode}/load:{baseline[index].get('dischargeState', 'unknown')}"]
            for key in keys:
                matched_full[key]["baseline"].append(old)
                matched_full[key]["candidate"].append(new)
        # Logged system ETA targets full charge/empty, so score independently only at 100/0.
        system_target = 100 if mode == "charging" else 0
        for position, index in enumerate(group):
            record = records[index]
            if index not in evaluated_indices or record["system"] is None:
                continue
            endpoint = next((other for other in group[position + 1:] if
                            (records[other]["percentage"] >= system_target if mode == "charging" else records[other]["percentage"] <= system_target)), None)
            if endpoint is not None:
                actual = (records[endpoint]["timestamp"] - record["timestamp"]) / 60
                if actual > 0:
                    full[f"{mode}/all"]["system"].append((record["system"], actual))
    stability = {}
    for name, predictions in (("baseline", baseline), ("candidate", candidate)):
        for mode in ("charging", "discharging"):
            indices = [i for i, record in enumerate(records)
                       if record["mode"] == mode and i in evaluated_indices]
            available = sum(predictions[i].get("minutes") is not None for i in indices)
            jumps = [abs(predictions[i]["minutes"] - predictions[i-1]["minutes"]) for i in indices if i > 0
                     and records[i-1]["mode"] == mode and records[i]["timestamp"] - records[i-1]["timestamp"] <= 180
                     and predictions[i].get("segment") == predictions[i-1].get("segment")
                     and predictions[i].get("minutes") is not None and predictions[i-1].get("minutes") is not None]
            stability[f"{name}/{mode}"] = {"observations": len(indices), "available": available,
                "coverage": available / len(indices) if indices else None,
                "systemFallback": sum(predictions[i].get("usedSystemEstimate") is True for i in indices),
                "sourceSwitches": sum(predictions[i].get("actualSource", predictions[i].get("predictionMethod")) != predictions[i-1].get("actualSource", predictions[i-1].get("predictionMethod")) for i in indices if i > 0 and records[i-1]["mode"] == mode),
                "medianJump": statistics.median(jumps) if jumps else None, "p90Jump": sorted(jumps)[max(0, math.ceil(len(jumps)*.9)-1)] if jumps else None}
    full_report = {key: {name: metrics(pairs) for name, pairs in values.items()} for key, values in full.items()}
    matched_report = {key: {name: metrics(pairs) for name, pairs in values.items()} for key, values in matched_full.items()}
    horizon_report, horizon_matched, horizon_counts = horizon10(
        records, {"baseline": baseline, "candidate": candidate},
        groups, evaluated_indices
    )
    blockers = []
    for category, report in (("probe", probe_report),
                             ("fullMatched", matched_report),
                             ("horizon10Matched", horizon_matched)):
        for key, values in report.items():
            for metric in ("mae", "p90"):
                old, new = values["baseline"][metric], values["candidate"][metric]
                if _is_material_regression(old, new):
                    blockers.append({"category": category, "group": key, "metric": metric, "baseline": old, "candidate": new})

    checks = []
    for mode in ("charging", "discharging"):
        coverage = stability[f"candidate/{mode}"]
        checks.append({
            "name": f"candidate {mode} coverage",
            "passed": coverage["coverage"] is not None and coverage["coverage"] > 0,
            "baseline": stability[f"baseline/{mode}"],
            "candidate": coverage,
            "rule": "candidate must produce at least one estimate in the holdout window",
        })
    empty = {"n": 0, "mae": None, "median": None, "mape": None, "p90": None}
    checks.append(_improvement_check(
        "discharge 10% horizon",
        horizon_matched.get("discharging/all", {"baseline": empty, "candidate": empty}),
        0.15, 0.10
    ))
    checks.append(_regression_check(
        "discharge full ETA",
        matched_report.get("discharging/all", {"baseline": empty, "candidate": empty})
    ))
    checks.append(_regression_check(
        "charging 2% probe",
        probe_report.get("charging/all", {"baseline": empty, "candidate": empty})
    ))
    checks.append(_regression_check(
        "charging full ETA",
        matched_report.get("charging/all", {"baseline": empty, "candidate": empty})
    ))
    checks.append(_regression_check(
        "charging 10% horizon",
        horizon_matched.get("charging/all", {"baseline": empty, "candidate": empty})
    ))
    acceptance = {
        "passed": all(check["passed"] for check in checks) and not blockers,
        "checks": checks,
    }
    return {
        "probes": probe_report, "fullETA": full_report,
        "fullETAMatched": matched_report, "horizon10": horizon_report,
        "horizon10Matched": horizon_matched, "sessions": details,
        "stability": stability, "blockers": blockers, "acceptance": acceptance,
        "evaluationWindow": {
            "holdoutDays": holdout_days,
            "cutoff": cutoff,
            "lastTimestamp": last_timestamp,
            "evaluatedRecords": len(evaluated_indices),
        },
        "horizon10Counts": horizon_counts,
        "probeCounts": {"baseline": len(bp), "candidate": len(cp), "matched": len(shared)},
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--logs", action="append", type=pathlib.Path, required=True)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    parser.add_argument("--baseline", default="57a7d30")
    parser.add_argument("--holdout-days", type=int, default=14)
    args = parser.parse_args()
    if args.holdout_days < 0:
        parser.error("--holdout-days must not be negative")
    output = args.output.resolve()
    if output == ROOT or ROOT in output.parents:
        parser.error("private replay outputs must be outside the repository")
    output.mkdir(parents=True, exist_ok=True)
    counts = {}
    records, invalid, conflicts = load_logs(args.logs, counts)
    if not records:
        parser.error("no valid telemetry records")
    (output / "excluded-same-timestamp.jsonl").write_text("".join(
        json.dumps(row, ensure_ascii=False) + "\n" for row in conflicts))
    with tempfile.TemporaryDirectory(prefix="status-trio-battery-replay-") as temporary:
        temporary = pathlib.Path(temporary)
        predictions = {}
        for name, revision in (("baseline", args.baseline), ("candidate", None)):
            directory = temporary / name
            directory.mkdir()
            executable = compile_model(directory, revision)
            predictions[name] = run_model(executable, records, output / f"{name}.jsonl")
    result = evaluate(records, predictions["baseline"], predictions["candidate"],
                      args.holdout_days)
    result.update({"records": len(records), "inputCounts": counts, "invalid": invalid, "sameTimestampConflicts": len(conflicts),
        "baselineRevision": args.baseline, "candidateHead": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
        "sourceHashes": {name: hashlib.sha256((ROOT / SOURCE_DIR / name).read_bytes()).hexdigest() for name in SOURCES},
        "limitations": ["Telemetry written before boundary reasons were added lacks explicit sleep/dirty markers; sleep correctness still requires regression tests.",
                         "Replay starts cold. The holdout window filters scoring only; both models keep learning chronologically during it.",
                         "Full ETA baseline and candidate may target different reserve levels; inspect session metrics and coverage, not aggregate error alone.",
                         "System ETA scores use 100/0 endpoints and are not matched to reserve ETA.",
                         "Repeated readings remain updates but completed probes are deduplicated; correlated observations are not independent sessions.",
                         "The 10% horizon compares each model's ETA at the starting row with its ETA at the first row that confirms the ten-point crossing; both rows must share the model's discharge reserve."]})
    (output / "report.json").write_text(json.dumps(result, indent=2, ensure_ascii=False))
    window = result["evaluationWindow"]
    window_start = (dt.datetime.fromtimestamp(window["cutoff"], dt.timezone.utc).isoformat()
                    if window["cutoff"] is not None else "全部记录")
    window_end = dt.datetime.fromtimestamp(window["lastTimestamp"], dt.timezone.utc).isoformat()
    lines = ["# 电池历史回放报告", "", f"原始行：{counts['rawLines']}；完整 JSON 重复：{counts['identicalJSONDuplicates']}；同时间不同内容排除：{len(conflicts)}；回放：{len(records)}；baseline：`{args.baseline}`。", "",
             f"评分留出期：{window_start} 至 {window_end}，共 {window['evaluatedRecords']} 条记录（{window['holdoutDays']} 天）；模型在此前记录上冷启动，并继续在线学习。", "",
             "同时间冲突明细保存在 excluded-same-timestamp.jsonl；源日志没有改动。回放条数不能作为恢复条数。", "",
             "两组均使用真实 Swift 模型顺序回放，首次启动不预置历史模型，完成 profile 只用于之后观测；候选在 segment 变化时合并部分充放电曲线。", "",
             "## 配对短程预测", "", "|方向/电量|样本|旧 MAE|新 MAE|旧 P90|新 P90|", "|---|---:|---:|---:|---:|---:|"]
    fmt = lambda value: "N/A" if value is None else f"{value:.3f}"
    for key, values in result["probes"].items():
        old, new = values["baseline"], values["candidate"]
        lines.append(f"|{key}|{old['n']}|{fmt(old['mae'])}|{fmt(new['mae'])}|{fmt(old['p90'])}|{fmt(new['p90'])}|")
    lines += ["", "## 10% 区间隐含时间", "", "同一连续 session 内取实际再变化 10 个百分点的耗时为真值；预测值为起点 ETA 减去跨过该变化时那一行的 ETA。放电两行必须使用相同 reserve。", "", "|方向/电量|样本|旧 MAE|新 MAE|旧 P90|新 P90|", "|---|---:|---:|---:|---:|---:|"]
    for key, values in result["horizon10Matched"].items():
        old, new = values["baseline"], values["candidate"]
        lines.append(f"|{key}|{old['n']}|{fmt(old['mae'])}|{fmt(new['mae'])}|{fmt(old['p90'])}|{fmt(new['p90'])}|")
    lines += ["", "## 配对全程 ETA", "", "两组只比较同一时间、同一目标端点的预测；负载分组使用 baseline 状态。未配对覆盖结果见 report.json。", "", "|方向/电量/负载|旧样本|新样本|旧 MAE|新 MAE|旧 P90|新 P90|", "|---|---:|---:|---:|---:|---:|---:|"]
    for key, values in result["fullETAMatched"].items():
        old, new = values["baseline"], values["candidate"]
        lines.append(f"|{key}|{old['n']}|{new['n']}|{fmt(old['mae'])}|{fmt(new['mae'])}|{fmt(old['p90'])}|{fmt(new['p90'])}|")
    lines += ["", "## 验收门槛", "", f"总体：{'通过' if result['acceptance']['passed'] else '未通过'}。", "", "|检查|结果|旧 MAE|新 MAE|旧 P90|新 P90|规则|", "|---|---|---:|---:|---:|---:|---|"]
    for check in result["acceptance"]["checks"]:
        old, new = check["baseline"], check["candidate"]
        lines.append(f"|{check['name']}|{'通过' if check['passed'] else '未通过'}|{fmt(old.get('mae'))}|{fmt(new.get('mae'))}|{fmt(old.get('p90'))}|{fmt(new.get('p90'))}|{check['rule']}|")
    lines += ["", f"超过 5% 且超过 1 分钟的 MAE/P90 实质恶化：{len(result['blockers'])} 项。详细分组及逐会话结果见 report.json。", "", "## 限制", ""]
    lines.extend(f"- {item}" for item in result["limitations"])
    (output / "report.md").write_text("\n".join(lines) + "\n")
    print(json.dumps({"report": str(output / "report.md"), "records": len(records),
                      "evaluatedRecords": window["evaluatedRecords"],
                      "blockers": len(result["blockers"]),
                      "accepted": result["acceptance"]["passed"]}))


if __name__ == "__main__":
    main()
