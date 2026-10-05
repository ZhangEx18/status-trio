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
           "BatteryLongTermBaseline.swift", "BatteryDataCleansing.swift"]


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
    # Worker may add shared continuity helpers; baseline intentionally excludes them.
    if not revision:
        for source in (ROOT / SOURCE_DIR).glob("Battery*Continuity*.swift"):
            destination = directory / source.name
            destination.write_bytes(source.read_bytes())
            paths.append(destination)
    main = directory / "main.swift"
    main.write_bytes((ROOT / "scripts/battery-replay/main.swift").read_bytes())
    executable = directory / "replay"
    subprocess.run(["swiftc", "-O", *map(str, paths), str(main), "-o", str(executable)], check=True)
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


def probes(records, predictions):
    result = {}
    for record, prediction in zip(records, predictions):
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


def evaluate(records, baseline, candidate):
    bp, cp = probes(records, baseline), probes(records, candidate)
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
    for number, group in enumerate(sessions(records, baseline, candidate)):
        first = records[group[0]]
        mode = first["mode"]
        if mode == "idle" or first["target"] is None:
            continue
        paired = {}
        # Use estimator's actual reserve: do not score a 10% ETA against a 0% endpoint.
        for model_name, predictions in (("baseline", baseline), ("candidate", candidate)):
            scores = []
            for position, index in enumerate(group):
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
            if record["system"] is None:
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
            indices = [i for i, record in enumerate(records) if record["mode"] == mode]
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
    blockers = []
    for category, groups in (("probe", probe_report), ("fullMatched", matched_report)):
        for key, values in groups.items():
            for metric in ("mae", "p90"):
                old, new = values["baseline"][metric], values["candidate"][metric]
                if old is not None and new is not None and new > old * 1.05:
                    blockers.append({"category": category, "group": key, "metric": metric, "baseline": old, "candidate": new})
    return {"probes": probe_report, "fullETA": full_report, "fullETAMatched": matched_report, "sessions": details,
            "stability": stability, "blockers": blockers,
            "probeCounts": {"baseline": len(bp), "candidate": len(cp), "matched": len(shared)}}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--logs", action="append", type=pathlib.Path, required=True)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    parser.add_argument("--baseline", default="38212e6")
    args = parser.parse_args()
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
    result = evaluate(records, predictions["baseline"], predictions["candidate"])
    result.update({"records": len(records), "inputCounts": counts, "invalid": invalid, "sameTimestampConflicts": len(conflicts),
        "baselineRevision": args.baseline, "candidateHead": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
        "sourceHashes": {name: hashlib.sha256((ROOT / SOURCE_DIR / name).read_bytes()).hexdigest() for name in SOURCES},
        "limitations": ["Old telemetry lacks explicit sleep/dirty boundary markers; sleep correctness requires regression tests.",
                         "Cold chronological start; no restored future samples or profiles seed either model.",
                         "Full ETA baseline and candidate may target different reserve levels; inspect session metrics and coverage, not aggregate error alone.",
                         "System ETA scores use 100/0 endpoints and are not matched to reserve ETA.",
                         "Repeated readings remain updates but completed probes are deduplicated; correlated observations are not independent sessions."]})
    (output / "report.json").write_text(json.dumps(result, indent=2, ensure_ascii=False))
    lines = ["# 电池历史回放报告", "", f"原始行：{counts['rawLines']}；完整 JSON 重复：{counts['identicalJSONDuplicates']}；同时间不同内容排除：{len(conflicts)}；回放：{len(records)}；baseline：{args.baseline}。", "",
             "同时间冲突明细保存在 excluded-same-timestamp.jsonl；源日志没有改动。回放条数不能作为恢复条数。", "",
             "两组均使用真实 Swift 模型顺序回放，首次启动不预置历史模型，完成 profile 只用于之后观测。", "",
             "## 配对短程预测", "", "|方向/电量|样本|旧 MAE|新 MAE|旧 P90|新 P90|", "|---|---:|---:|---:|---:|---:|"]
    fmt = lambda value: "N/A" if value is None else f"{value:.3f}"
    for key, values in result["probes"].items():
        old, new = values["baseline"], values["candidate"]
        lines.append(f"|{key}|{old['n']}|{fmt(old['mae'])}|{fmt(new['mae'])}|{fmt(old['p90'])}|{fmt(new['p90'])}|")
    lines += ["", "## 配对全程 ETA", "", "两组只比较同一时间、同一目标端点的预测；负载分组使用 baseline 状态。未配对覆盖结果见 report.json。", "", "|方向/电量/负载|旧样本|新样本|旧 MAE|新 MAE|旧 P90|新 P90|", "|---|---:|---:|---:|---:|---:|---:|"]
    for key, values in result["fullETAMatched"].items():
        old, new = values["baseline"], values["candidate"]
        lines.append(f"|{key}|{old['n']}|{new['n']}|{fmt(old['mae'])}|{fmt(new['mae'])}|{fmt(old['p90'])}|{fmt(new['p90'])}|")
    lines += ["", "## 回归门槛", "", f"超过 5% 的 MAE/P90 恶化：{len(result['blockers'])} 项。详细分组及逐会话结果见 report.json。", "", "## 限制", ""]
    lines.extend(f"- {item}" for item in result["limitations"])
    (output / "report.md").write_text("\n".join(lines) + "\n")
    print(json.dumps({"report": str(output / "report.md"), "records": len(records), "blockers": len(result["blockers"])}))


if __name__ == "__main__":
    main()
