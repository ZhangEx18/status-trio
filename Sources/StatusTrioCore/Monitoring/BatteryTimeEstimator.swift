import Foundation

/// Learns separate discharge and charge profiles from continuous battery activity.
struct BatteryTimeEstimator {
    struct Diagnostics: Sendable {
        var mode: String?
        /// The live discharge regime.  This is deliberately diagnostic data so
        /// telemetry can tell whether a forecast came from the long-term
        /// baseline or from the short-lived load detector.
        var dischargeState: String? = nil
        var validRateCount = 0
        var baselineRate: Double?
        var recentRate: Double?
        var selectedRate: Double?
        var reservePercent: Double?
        var usedSystemEstimate = false
        var chargingThermalThrottled = false
        var missingChargeBandStartPercent: Double?
        var completedBandObservationCount = 0
        var recentCorrectionFactor: Double?
        var predictionMethod: String?
        var rawETA: Double?
        var actualSource: String? = "unavailable"
        var nextTwoPercentMinutes: Double?
        var pendingProbeTargetPercent: Double?
        var pendingProbeBaselineMinutes: Double?
        var pendingProbePredictedMinutes: Double?
        var completedProbeStartedAt: Date?
        var completedProbeCrossedAt: Date?
        var completedProbeFromPercent: Double?
        var completedProbeTargetPercent: Double?
        var completedProbeBaselineMinutes: Double?
        var completedProbeBaselineErrorRatio: Double?
        var completedProbePredictedMinutes: Double?
        var completedProbeActualMinutes: Double?
        var completedProbePredictionErrorRatio: Double?

        /// Kept as a compatibility alias for older diagnostic consumers.
        var completedProbeErrorRatio: Double? {
            completedProbePredictionErrorRatio
        }
    }

    struct Sample: Codable, Equatable {
        enum Source: String, Codable { case iops, legacy, thermal }
        let date: Date
        let percentage: Double
        let charging: Bool
        let target: Double?
        let connectedToPower: Bool
        let segment: Int
        enum BoundaryReason: String, Codable { case sleepWake, restore, gap, powerTransition, target, capacityJump }
        let boundaryReason: BoundaryReason?
        let source: Source

        init(date: Date, percentage: Double, charging: Bool, target: Double?,
             connectedToPower: Bool? = nil, segment: Int = 0,
             source: Source = .iops, boundaryReason: BoundaryReason? = nil) {
            self.date = date
            self.percentage = percentage
            self.charging = charging
            self.target = target
            self.connectedToPower = connectedToPower ?? charging
            self.segment = segment
            self.source = source
            self.boundaryReason = boundaryReason
        }

        // The previous on-disk format had no power-state marker or segment ID.
        // A legacy 100% charge target may mean a failed private API read, so it
        // must not be promoted to a confirmed 100% limit.
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            date = try values.decode(Date.self, forKey: .date)
            percentage = try values.decode(Double.self, forKey: .percentage)
            charging = try values.decode(Bool.self, forKey: .charging)
            connectedToPower = try values.decodeIfPresent(Bool.self, forKey: .connectedToPower) ?? charging
            segment = try values.decodeIfPresent(Int.self, forKey: .segment) ?? 0
            source = try values.decodeIfPresent(Source.self, forKey: .source) ?? .legacy
            boundaryReason = try values.decodeIfPresent(BoundaryReason.self, forKey: .boundaryReason)
            let oldTarget = try values.decodeIfPresent(Double.self, forKey: .target)
            target = values.contains(.connectedToPower) ? oldTarget
                : (charging && oldTarget == 100 ? nil : oldTarget)
        }

        private enum CodingKeys: String, CodingKey {
            case date, percentage, charging, target, connectedToPower, segment, source, boundaryReason
        }

        var mode: Mode {
            if !connectedToPower { return .discharging }
            return charging ? .charging : .idle
        }
    }

    enum Mode { case charging, discharging, idle }
    /// Profile seeding may cross an estimator reset only when adjacent IOPS
    /// samples remain continuous; idle, thermal, direction, and sleep breaks still reset it.
    enum BandSegmentPolicy: Equatable, Sendable {
        case sameEstimatorSegment
        case verifiedContinuousSamples
    }
    private struct Rate {
        let value: Double             // percentage points per minute
        let duration: TimeInterval
        var startDate: Date { date.addingTimeInterval(-duration) }
        let date: Date
        let segment: Int
        let midpoint: Double
    }
    struct BandObservation {
        let lowerPercent: Int
        let minutes: Double
        let date: Date
        let segment: Int
    }
    private struct ShortProbe {
        let date: Date
        let fromPercent: Double
        let targetPercent: Double
        let baselineMinutes: Double?
        let predictedMinutes: Double
        let segment: Int
    }

    /// Raw observations are retained long enough to follow battery ageing.
    /// The robust median below still discounts old observations, so retaining
    /// 60 days does not make a stale workload dominate a new one.
    static let persistenceHorizon: TimeInterval = BatteryLongTermBaseline.retentionHorizon
    static let maximumPersistedSamples = 25_000
    static let maximumGap: TimeInterval = 3 * 60
    static let maximumSegmentCapacityChange = 4.0
    /// Keep the live load estimate responsive; historical profiles remain
    /// long-lived and are unaffected by this short window.
    private static let recentWindow: TimeInterval = 5 * 60
    private static let recentSmoothingTime: TimeInterval = 2 * 60
    private static let minimumRate = 0.01
    private static let lowBatteryDamping = 0.72
    private static let dynamicHorizonPercent = 10.0

    private(set) var samples: [Sample] = []
    private var smoothedRate: Double?
    private var smoothedAt: Date?
    private var lastDisplayed: (date: Date, minutes: Double, segment: Int)?
    private var liveSegmentStartedAt: Date?
    private var nextSampleStartsSegment = false
    private var pendingBoundaryReason: Sample.BoundaryReason?
    private(set) var diagnostics = Diagnostics(mode: nil)
    private var pendingProbe: ShortProbe?
    private var lastProbeMinutesPerPoint: Double?
    private var dischargeStateMachine = BatteryDischargeStateMachine()
    private var profiles: BatteryTimeProfileCatalog
    /// A cycle-local reference used only when a physical charge band has not
    /// been learned yet.  It is never written into the long-term profile, so
    /// thermal throttling cannot permanently slow the model.
    private var chargingReferenceMinutesPerPoint: Double?

    init(samples: [Sample] = [], profiles: BatteryTimeProfileCatalog = .init()) {
        self.samples = samples
        self.profiles = profiles
    }
    var persistedSamples: [Sample] { Array(samples.suffix(Self.maximumPersistedSamples)) }

    mutating func updateProfiles(_ profiles: BatteryTimeProfileCatalog) {
        self.profiles = profiles
    }

    mutating func restore(_ stored: [Sample], now: Date) {
        samples = stored.filter {
            $0.date <= now && now.timeIntervalSince($0.date) <= Self.persistenceHorizon
                && $0.percentage.isFinite && (0...100).contains($0.percentage)
                && ($0.target == nil || ($0.target!.isFinite && (0...100).contains($0.target!)))
                && $0.segment >= 0
        }.sorted { $0.date < $1.date }.suffix(Self.maximumPersistedSamples)
        resetCurrentPrediction()
    }

    mutating func resetCurrentPrediction() {
        smoothedRate = nil
        smoothedAt = nil
        lastDisplayed = nil
        liveSegmentStartedAt = nil
        nextSampleStartsSegment = true
        pendingBoundaryReason = .restore
        diagnostics = Diagnostics(mode: nil)
        pendingProbe = nil
        lastProbeMinutesPerPoint = nil
        dischargeStateMachine.reset()
        chargingReferenceMinutesPerPoint = nil
    }

    /// Invalidates only the live interval after sleep or a power-source
    /// transition.  Historical samples remain available for the long-term
    /// baseline, but no rate is allowed to bridge the dirty interval.
    mutating func markDirtyInterval(reason: Sample.BoundaryReason = .sleepWake) {
        nextSampleStartsSegment = true
        pendingBoundaryReason = reason
        clearLiveFilters()
        dischargeStateMachine.reset()
        chargingReferenceMinutesPerPoint = nil
        diagnostics.dischargeState = "baseline"
    }

    /// Records idle power transitions too. No estimate is shown while plugged
    /// in but not charging. Unknown charge limits remain nil.
    mutating func add(date: Date, percentage: Double, charging: Bool, target: Double?,
                      connectedToPower: Bool? = nil, systemMinutes: Int? = nil) -> Int? {
        let connected = connectedToPower ?? charging
        guard percentage.isFinite, (0...100).contains(percentage),
              target == nil || (target!.isFinite && (0...100).contains(target!)) else { return nil }
        let mode: Mode = connected ? (charging ? .charging : .idle) : .discharging
        let normalizedTarget = mode == .charging ? target : (mode == .discharging ? 0 : nil)
        var shouldRecord = true
        if let last = samples.last {
            guard date > last.date else { return nil }
            if date.timeIntervalSince(last.date) < 60, last.percentage == percentage,
               last.mode == mode, last.target == normalizedTarget, !nextSampleStartsSegment {
                if mode != .charging { return lastDisplayed.map { Int($0.minutes.rounded()) } }
                // Re-evaluate the live system estimate without inventing another
                // unchanged capacity observation or carrying its stale result forward.
                shouldRecord = false
            }
        }
        diagnostics = Diagnostics(mode: mode == .idle ? "mixedPower" : String(describing: mode))
        let last = samples.last
        let gap = last.map { date.timeIntervalSince($0.date) } ?? 0
        let change = percentage - (last?.percentage ?? percentage)
        let implausible = gap <= Self.maximumGap && (
            abs(change) > Self.maximumSegmentCapacityChange || (mode == .discharging && change > 1)
                || (mode == .charging && change < -1)
        )
        let boundary = nextSampleStartsSegment || last.map {
            $0.mode != mode || $0.target != normalizedTarget || gap > Self.maximumGap
        } == true || implausible
        let boundaryReason: Sample.BoundaryReason? = pendingBoundaryReason
            ?? (gap > Self.maximumGap ? .gap : nil)
            ?? (implausible ? .capacityJump : nil)
            ?? (last.map { $0.mode != mode } == true ? .powerTransition : nil)
            ?? (last.map { $0.target != normalizedTarget } == true ? .target : nil)
        if boundary {
            dischargeStateMachine.reset()
            chargingReferenceMinutesPerPoint = nil
            clearLiveFilters()
            liveSegmentStartedAt = date
            if last?.mode != mode || gap > Self.maximumGap {
                chargingReferenceMinutesPerPoint = nil
            }
        }
        if liveSegmentStartedAt == nil {
            liveSegmentStartedAt = date
        }
        let segment = (last?.segment ?? 0) + (boundary ? 1 : 0)
        nextSampleStartsSegment = false
        pendingBoundaryReason = nil
        var thermalThrottled = false
        let sample = Sample(date: date, percentage: percentage, charging: charging,
                            target: normalizedTarget, connectedToPower: connected, segment: segment,
                            source: .iops, boundaryReason: boundaryReason)
        if mode == .charging, let last, percentage < 80,
           BatterySampleContinuity.canContinue(last, sample), change > 0 {
            let candidate = gap / 60 / change
            thermalThrottled = chargingReferenceMinutesPerPoint.map { candidate > $0 * 1.5 } ?? false
            if (0.05...30).contains(candidate), !thermalThrottled {
                chargingReferenceMinutesPerPoint = candidate
            }
        }
        // Compatibility diagnostic: a rate slowdown is not confirmed thermal throttling.
        diagnostics.chargingThermalThrottled = thermalThrottled
        let recorded = Sample(date: sample.date, percentage: sample.percentage,
            charging: sample.charging, target: sample.target, connectedToPower: sample.connectedToPower,
            segment: sample.segment, source: .iops,
            boundaryReason: sample.boundaryReason)
        if shouldRecord { samples.append(recorded) }
        samples.removeAll { date.timeIntervalSince($0.date) > Self.persistenceHorizon }
        if samples.count > Self.maximumPersistedSamples {
            samples.removeFirst(samples.count - Self.maximumPersistedSamples)
        }
        guard mode != .idle else { return nil }

        let bands = completedBands(mode: mode, target: normalizedTarget)
        diagnostics.completedBandObservationCount = bands.count
        if let last, !BatterySampleContinuity.canContinue(last, recorded) {
            pendingProbe = nil
            lastProbeMinutesPerPoint = nil
        }
        updateShortProbe(date: date, percentage: percentage, mode: mode,
                         target: normalizedTarget, segment: segment, prior: last, bands: bands)
        let rawMinutes: Double?
        if mode == .discharging {
            let rates = (validRates(mode: mode, target: normalizedTarget)
                + fragmentRates(mode: mode, target: normalizedTarget))
                .sorted { $0.date < $1.date }
            // The active segment is evidence for the dynamic predictor, not
            // training data for the long-term baseline.  This is what keeps a
            // sustained workload from rewriting the battery's history.
            let historicalRates = rates.filter { $0.segment != segment }
            let cleanHistoricalRates = historicalRates.filter { (10..<95).contains($0.midpoint) }
            let baselineRates: [Rate]
            if !cleanHistoricalRates.isEmpty {
                baselineRates = cleanHistoricalRates
            } else if historicalRates.isEmpty {
                // A first session has no baseline yet; a continuous fragment
                // can still provide a provisional estimate.
                baselineRates = rates
            } else {
                // History made only of reserve or top-of-charge intervals is
                // intentionally unusable as a normal discharge baseline.
                baselineRates = []
            }
            diagnostics.validRateCount = baselineRates.count
            let baseline = weightedMedian(baselineRates, now: date)
            diagnostics.baselineRate = baseline
            let liveIntervals = recentDischargeIntervals(date: date, segment: segment)
            let recent = recentRate(rates, date: date, segment: segment)
                ?? liveIntervals.last?.value
            diagnostics.recentRate = recent
            if let baseline {
                updateDischargeState(baseline: baseline, date: date, segment: segment)
            } else {
                dischargeStateMachine.reset()
            }
            diagnostics.dischargeState = dischargeStateName
            // Keep the sub-10% tail out of the long-term band model.  The
            // reserve floor is handled by the rate fallback and damping.
            let profileTarget = profiles.hasProfile(
                direction: .discharging,
                targetPercent: 5,
                now: date
            ) ? 5.0 : 10.0
            if let profile = profileMinutes(from: percentage, to: profileTarget, mode: mode,
                                            bands: bands, segment: segment, date: date) {
                diagnostics.reservePercent = 5
                rawMinutes = profile
            } else {
                let hasContinuousFragment = rates.contains { $0.duration >= 5 * 60 }
                guard let baseline, rates.count >= 5 || hasContinuousFragment else { return nil }
                let rate = selectedDischargeRate(baseline: baseline, recent: recent)
                diagnostics.selectedRate = rate
                // Low-battery IOKit time may calibrate the unobservable shutdown floor.
                let osFloor = systemMinutes.flatMap { minutes -> Double? in
                    guard percentage <= 20, minutes > 0 else { return nil }
                    let candidate = percentage - Double(minutes) * rate
                    return (0...10).contains(candidate) ? candidate : nil
                }
                diagnostics.reservePercent = osFloor ?? 5
                diagnostics.usedSystemEstimate = osFloor != nil
                diagnostics.predictionMethod = "rateFallback"
                rawMinutes = fallbackDischargeMinutes(
                    from: percentage,
                    reserve: osFloor ?? 5,
                    baseline: baseline,
                    recent: recent
                )
            }
        } else {
            guard let target = normalizedTarget, target > percentage else { return nil }
            if let profile = profileMinutes(from: percentage, to: target, mode: mode,
                                             bands: bands, segment: segment, date: date) {
                rawMinutes = profile
                diagnostics.actualSource = "historicalCurve"
            } else if let systemMinutes, (1...1440).contains(systemMinutes) {
                rawMinutes = Double(systemMinutes)
                diagnostics.usedSystemEstimate = true
                diagnostics.predictionMethod = "systemEstimate"
                diagnostics.actualSource = "systemEstimate"
            } else {
                rawMinutes = physicalChargeMinutes(from: percentage, to: target)
                diagnostics.actualSource = rawMinutes == nil ? "unavailable" : "physicalFallback"
            }
        }
        diagnostics.rawETA = rawMinutes
        if diagnostics.actualSource == "unavailable", rawMinutes != nil { diagnostics.actualSource = diagnostics.predictionMethod }
        guard let rawMinutes, rawMinutes.isFinite, (1...1440).contains(rawMinutes) else { return nil }
        let displayed: Double
        if diagnostics.usedSystemEstimate {
            displayed = rawMinutes
        } else if let previous = lastDisplayed, previous.segment == segment {
            let elapsed = max(0, date.timeIntervalSince(previous.date) / 60)
            let segmentAge = liveSegmentStartedAt.map { date.timeIntervalSince($0) } ?? 0
            if mode == .discharging,
               dischargeStateMachine.state != .highLoad,
               segmentAge < 2 * 60 {
                // State A/B keeps a short recalibration from making the
                // displayed total jump on every 1% sample.  Once the segment
                // has proved stable, the ordinary bounded slew resumes.
                displayed = max(previous.minutes, rawMinutes)
            } else {
                let ordinaryPermitted = percentage <= 20 ? 15 + elapsed * 10 : 5 + elapsed * 3
                let permitted = segmentAge >= 15 * 60 && percentage <= 50
                    ? max(ordinaryPermitted, 15 + elapsed * 10)
                    : ordinaryPermitted
                displayed = min(previous.minutes + permitted,
                                max(previous.minutes - permitted, rawMinutes))
            }
        } else {
            displayed = rawMinutes
        }
        lastDisplayed = (date, displayed, segment)
        return Int(displayed.rounded())
    }

    private mutating func clearLiveFilters() {
        smoothedRate = nil
        smoothedAt = nil
        lastDisplayed = nil
        liveSegmentStartedAt = nil
        pendingProbe = nil
        lastProbeMinutesPerPoint = nil
    }

    private var dischargeStateName: String {
        dischargeStateMachine.state.rawValue
    }

    /// Uses non-overlapping adjacent capacity intervals for the live load
    /// detector. A single fast interval is only a transient; two in a row
    /// are required before the high-load state is entered.
    private func recentDischargeIntervals(date: Date, segment: Int) -> [Rate] {
        let current = samples.filter {
            $0.segment == segment && $0.mode == .discharging && $0.date <= date
        }
        guard current.count >= 2 else { return [] }
        var result: [Rate] = []
        var endIndex = current.count - 1
        while endIndex > 0 {
            let end = current[endIndex]
            var startIndex = endIndex - 1
            while startIndex >= 0 {
                let start = current[startIndex]
                let duration = end.date.timeIntervalSince(start.date)
                let drop = start.percentage - end.percentage
                if duration >= 30, duration <= 10 * 60,
                   (0.25...4.0).contains(drop),
                   hasContinuousSamples(current, from: startIndex, through: endIndex),
                   date.timeIntervalSince(end.date) <= 45 * 60 {
                    result.append(Rate(value: drop / (duration / 60),
                                       duration: duration,
                                       date: end.date,
                                       segment: segment,
                                       midpoint: (start.percentage + end.percentage) / 2))
                    // Move before the interval just consumed so the next
                    // interval cannot overlap it.
                    endIndex = startIndex
                    break
                }
                if duration > 10 * 60 { endIndex = startIndex; break }
                startIndex -= 1
            }
            if startIndex < 0 { break }
            if startIndex == endIndex - 1 { break }
        }
        return result.reversed()
    }

    private func hasContinuousSamples(_ samples: [Sample], from start: Int,
                                      through end: Int) -> Bool {
        guard start < end else { return true }
        for index in (start + 1)...end {
            if !BatterySampleContinuity.canContinue(samples[index - 1], samples[index]) {
                return false
            }
        }
        return true
    }

    private mutating func updateDischargeState(baseline: Double,
                                               date: Date,
                                               segment: Int) {
        guard baseline > 0 else { return }
        let intervals = recentDischargeIntervals(date: date, segment: segment)
        dischargeStateMachine.update(
            baseline: baseline,
            recentIntervals: intervals.map { .init(segment: $0.segment, start: $0.startDate, end: $0.date, rate: $0.value) }
        )
    }

    private func selectedDischargeRate(baseline: Double, recent: Double?) -> Double {
        dischargeStateMachine.selectedRate(baseline: baseline, recent: recent)
    }

    private func fallbackDischargeMinutes(from percentage: Double,
                                           reserve: Double,
                                           baseline: Double,
                                           recent: Double?) -> Double {
        let usable = max(0, percentage - reserve)
        guard usable > 0 else { return 0 }
        let horizon = dischargeStateMachine.state == .transient
            ? 2.0 : Self.dynamicHorizonPercent
        let near = min(horizon, usable)
        let nearRate = selectedDischargeRate(baseline: baseline, recent: recent)
        let farRate = baseline
        let nearMinutes = near / max(Self.minimumRate, nearRate)
        let farMinutes = max(0, usable - near) / max(Self.minimumRate, farRate)
        let damping = percentage < 10 ? Self.lowBatteryDamping : 1
        return (nearMinutes + farMinutes) * damping
    }

    private mutating func updateShortProbe(date: Date, percentage: Double, mode: Mode,
                                           target: Double?, segment: Int, prior: Sample?,
                                           bands: [BandObservation]) {
        if let probe = pendingProbe, probe.segment == segment {
            let crossed = mode == .charging
                ? percentage >= probe.targetPercent : percentage <= probe.targetPercent
            if crossed, let prior, prior.segment == segment {
                let change = percentage - prior.percentage
                let fraction = change == 0 ? 1
                    : (probe.targetPercent - prior.percentage) / change
                let crossedAt = prior.date.addingTimeInterval(
                    date.timeIntervalSince(prior.date) * min(1, max(0, fraction))
                )
                let actual = crossedAt.timeIntervalSince(probe.date) / 60
                let span = abs(probe.targetPercent - probe.fromPercent)
                if actual > 0, span > 0, probe.predictedMinutes > 0 {
                    diagnostics.completedProbeStartedAt = probe.date
                    diagnostics.completedProbeCrossedAt = crossedAt
                    diagnostics.completedProbeFromPercent = probe.fromPercent
                    diagnostics.completedProbeTargetPercent = probe.targetPercent
                    diagnostics.completedProbeBaselineMinutes = probe.baselineMinutes
                    diagnostics.completedProbePredictedMinutes = probe.predictedMinutes
                    diagnostics.completedProbeActualMinutes = actual
                    diagnostics.completedProbePredictionErrorRatio = actual / probe.predictedMinutes
                    if let baseline = probe.baselineMinutes, baseline > 0 {
                        diagnostics.completedProbeBaselineErrorRatio = actual / baseline
                    }
                    lastProbeMinutesPerPoint = actual / span
                }
                pendingProbe = nil
            }
        }
        guard pendingProbe == nil,
              let local = recentFiveMinutes(at: percentage, mode: mode,
                                            segment: segment, date: date) else {
            diagnostics.pendingProbeTargetPercent = pendingProbe?.targetPercent
            diagnostics.pendingProbeBaselineMinutes = pendingProbe?.baselineMinutes
            diagnostics.pendingProbePredictedMinutes = pendingProbe?.predictedMinutes
            return
        }
        let end = mode == .charging ? target : 5
        guard let end else { return }
        let remaining = mode == .charging ? end - percentage : percentage - end
        guard remaining > 0 else { return }
        let span = min(2, remaining)
        guard span >= 1 else { return }
        let localRate = local / 5
        let previous = lastProbeMinutesPerPoint.map {
            min(2 * localRate, max(0.5 * localRate, $0))
        }
        let adjustedRate = previous.map { (localRate + $0) / 2 } ?? localRate
        let probeTarget = percentage + (mode == .charging ? span : -span)
        let baseline = profileBaseMinutes(from: percentage, to: probeTarget,
                                          mode: mode, bands: bands, segment: segment,
                                          date: date)
        let forecast = ShortProbe(date: date, fromPercent: percentage,
                                  targetPercent: probeTarget, baselineMinutes: baseline,
                                  predictedMinutes: adjustedRate * span, segment: segment)
        pendingProbe = forecast
        diagnostics.pendingProbeTargetPercent = forecast.targetPercent
        diagnostics.pendingProbeBaselineMinutes = forecast.baselineMinutes
        diagnostics.pendingProbePredictedMinutes = forecast.predictedMinutes
    }

    private func validRates(mode: Mode, target: Double?) -> [Rate] {
        var result: [Rate] = []
        for end in samples.indices.dropFirst() {
            let next = samples[end]
            guard next.mode == mode, next.target == target else { continue }
            var start = end
            while start > 0 {
                let prior = samples[start - 1]
                let later = samples[start]
                guard BatterySampleContinuity.canContinue(prior, later),
                      prior.mode == mode, prior.target == target else { break }
                start -= 1
                let duration = next.date.timeIntervalSince(prior.date)
                if duration < (mode == .charging ? 5 : 10) * 60 { continue }
                if duration > 15 * 60 { break }
                let change = mode == .charging
                    ? next.percentage - prior.percentage
                    : prior.percentage - next.percentage
                let rate = change / (duration / 60)
                if (Self.minimumRate...2).contains(rate) {
                    result.append(Rate(value: rate, duration: duration,
                                       date: next.date, segment: next.segment,
                                       midpoint: (prior.percentage + next.percentage) / 2))
                }
                break
            }
        }
        return result
    }

    /// Reassembles sparse readings into a single usable sample once more than
    /// three capacity points have been crossed.  This prevents a quiet but
    /// continuous discharge from starving the model simply because the IOPS
    /// callback did not arrive on every 1% boundary.
    private func fragmentRates(mode: Mode, target: Double?) -> [Rate] {
        guard mode != .idle else { return [] }
        var result: [Rate] = []
        var anchor: Sample?
        var previous: Sample?
        for sample in samples {
            guard sample.mode == mode, sample.target == target else {
                anchor = nil
                previous = nil
                continue
            }
            if let previous, !BatterySampleContinuity.canContinue(previous, sample) {
                anchor = sample
            }
            guard let start = anchor else {
                anchor = sample
                previous = sample
                continue
            }
            if start.date == sample.date {
                previous = sample
                continue
            }
            let duration = sample.date.timeIntervalSince(start.date)
            let change = mode == .charging
                ? sample.percentage - start.percentage
                : start.percentage - sample.percentage
            if change <= 0 {
                anchor = sample
                previous = sample
                continue
            }
            guard duration >= 5 * 60 else {
                previous = sample
                continue
            }
            guard change > 3, (Self.minimumRate...2).contains(change / (duration / 60)) else {
                previous = sample
                continue
            }
            result.append(Rate(value: change / (duration / 60),
                               duration: duration,
                               date: sample.date,
                               segment: sample.segment,
                               midpoint: (start.percentage + sample.percentage) / 2))
            anchor = sample
            previous = sample
        }
        return result
    }

    private func weightedMedian(_ rates: [Rate], now: Date? = nil) -> Double? {
        BatteryLongTermBaseline.weightedMedian(rates.map {
            BatteryLongTermBaseline.Observation(
                value: $0.value,
                duration: $0.duration,
                date: $0.date
            )
        }, now: now)
    }

    private mutating func recentRate(_ rates: [Rate], date: Date, segment: Int) -> Double? {
        let recent = rates.filter {
            $0.segment == segment && $0.date.timeIntervalSince(date) >= -Self.recentWindow
        }
        guard recent.count >= 4, let latest = recent.last else { return nil }
        let observed = latest.value
        let elapsed = smoothedAt.map { max(0, date.timeIntervalSince($0)) } ?? Self.recentWindow
            let alpha = 1 - exp(-elapsed / Self.recentSmoothingTime)
        let next = smoothedRate.map { $0 + alpha * (observed - $0) } ?? observed
        smoothedRate = next
        smoothedAt = date
        return next
    }

    /// One observation per fully crossed five-point band. Crossing times are
    /// interpolated from IOPS percentages, never system-time or power estimates.
    func completedBands(
        mode: Mode,
        target: Double?,
        segmentPolicy: BandSegmentPolicy = .sameEstimatorSegment
    ) -> [BandObservation] {
        var observations: [BandObservation] = []
        var previous: Sample?
        var crossing: (percent: Int, date: Date)?
        for sample in samples {
            guard sample.mode == mode, sample.target == target, sample.source == .iops else {
                previous = nil
                crossing = nil
                continue
            }
            guard let prior = previous,
                  BatterySampleContinuity.canContinue(prior, sample) else {
                previous = sample
                let boundary = (sample.percentage / 5).rounded() * 5
                crossing = abs(sample.percentage - boundary) < 0.000001
                    ? (Int(boundary), sample.date) : nil
                continue
            }
            defer { previous = sample }
            let gap = sample.date.timeIntervalSince(prior.date)
            guard gap > 0, gap <= Self.maximumGap else { crossing = nil; continue }
            let change = sample.percentage - prior.percentage
            guard mode == .charging ? change >= 0 : change <= 0 else {
                crossing = nil
                continue
            }
            if segmentPolicy == .verifiedContinuousSamples,
               abs(change) > Self.maximumSegmentCapacityChange {
                crossing = nil
                continue
            }
            guard change != 0 else { continue }
            let first = mode == .charging
                ? Int(floor(prior.percentage / 5) + 1) * 5
                : Int(ceil(prior.percentage / 5) - 1) * 5
            let last = mode == .charging
                ? Int(floor(sample.percentage / 5)) * 5
                : Int(floor(sample.percentage / 5)) * 5
            let boundaries = mode == .charging
                ? stride(from: first, through: last, by: 5).map { $0 }
                : stride(from: first, through: last, by: -5).map { $0 }
            for boundary in boundaries {
                let fraction = (Double(boundary) - prior.percentage) / change
                guard (0...1).contains(fraction) else { continue }
                let crossedAt = prior.date.addingTimeInterval(gap * fraction)
                if let crossing, abs(crossing.percent - boundary) == 5 {
                    let minutes = crossedAt.timeIntervalSince(crossing.date) / 60
                    if (2.5...500).contains(minutes) {
                        observations.append(BandObservation(
                            lowerPercent: min(crossing.percent, boundary),
                            minutes: minutes, date: crossedAt, segment: sample.segment
                        ))
                    }
                }
                crossing = (boundary, crossedAt)
            }
        }
        return observations
    }

    private func bandMinutes(_ lower: Int, in bands: [BandObservation],
                             mode: Mode, excluding segment: Int,
                             now: Date? = nil) -> Double? {
        let matching = bands.filter {
            guard $0.lowerPercent == lower, $0.segment != segment else { return false }
            // The top 5% hides charge and discharge transitions, while the
            // bottom 10% is dominated by voltage collapse.  Keep the charge
            // curve's upper taper, but never let either extreme train the
            // discharge baseline.
            if mode == .discharging {
                return (10..<95).contains($0.lowerPercent)
            }
            return true
        }
        guard !matching.isEmpty else { return nil }
        return BatteryLongTermBaseline.robustWeightedMedian(matching.map {
            BatteryLongTermBaseline.Observation(
                value: $0.minutes,
                duration: 1,
                date: $0.date
            )
        }, now: now)
    }

    private func recentFiveMinutes(at percentage: Double, mode: Mode,
                                   segment: Int, date: Date) -> Double? {
        let threshold = percentage + (mode == .charging ? -5 : 5)
        let current = samples.filter { $0.segment == segment }
        guard current.count >= 2 else { return nil }
        for index in (1..<current.count).reversed() {
            let earlier = current[index - 1]
            let later = current[index]
            let crosses = mode == .charging
                ? earlier.percentage <= threshold && later.percentage >= threshold
                : earlier.percentage >= threshold && later.percentage <= threshold
            guard crosses, hasContinuousSamples(current, from: index - 1, through: current.count - 1) else { continue }
            let change = later.percentage - earlier.percentage
            let crossedAt = change == 0 ? earlier.date : earlier.date.addingTimeInterval(
                later.date.timeIntervalSince(earlier.date)
                    * (threshold - earlier.percentage) / change
            )
            let elapsed = date.timeIntervalSince(crossedAt) / 60
            return (2.5...500).contains(elapsed) ? elapsed : nil
        }
        return nil
    }

    private mutating func profileMinutes(from percentage: Double, to target: Double,
                                         mode: Mode, bands: [BandObservation],
                                         segment: Int, date: Date) -> Double? {
        guard mode == .charging ? target > percentage : percentage > target else { return nil }
        let local = recentFiveMinutes(at: percentage, mode: mode, segment: segment, date: date)
        let localSpan = min(2, abs(target - percentage))
        let localRate = local.map { $0 / 5 }
        let adjustedRate = localRate.map { rate in
            let previous = lastProbeMinutesPerPoint.map {
                min(2 * rate, max(0.5 * rate, $0))
            }
            return previous.map { (rate + $0) / 2 } ?? rate
        }
        diagnostics.nextTwoPercentMinutes = adjustedRate.map { $0 * localSpan }
        var position = percentage
        var total = 0.0
        var usedLocalProfile = false
        if let local,
           let prior = profileBaseMinutes(from: mode == .charging ? percentage - 5 : percentage + 5,
                                          to: percentage, mode: mode, bands: bands,
                                          segment: segment, date: date) {
        diagnostics.recentCorrectionFactor = local / prior
        }
        while mode == .charging ? position < target : position > target {
            let lower = mode == .charging
                ? Int(floor(position / 5)) * 5 : Int(ceil(position / 5) - 1) * 5
            let next = mode == .charging
                ? min(target, Double(lower + 5)) : max(target, Double(lower))
            let distance = abs(next - position)
            guard distance > 0 else { return nil }
            let profileDirection: BatteryTimeProfile.Direction =
                mode == .charging ? .charging : .discharging
            let profileTargetPercent = mode == .charging
                ? Int(target.rounded()) : 5
            let localBaseline = profiles.minutesPerBand(
                direction: profileDirection,
                targetPercent: profileTargetPercent,
                lowerPercent: lower,
                now: date
            )
            if localBaseline != nil { usedLocalProfile = true }
            if let baseline = localBaseline
                ?? bandMinutes(lower, in: bands, mode: mode, excluding: segment, now: date) {
                total += effectiveBandMinutes(
                    baseline: baseline,
                    distance: distance,
                    from: position,
                    start: percentage,
                    mode: mode,
                    baselineRateOverride: localBaseline.map { 5 / $0 }
                )
            } else {
                if mode == .charging { diagnostics.missingChargeBandStartPercent = Double(lower) }
                diagnostics.predictionMethod = nil
                return nil
            }
            position = next
        }
        diagnostics.predictionMethod = "intervalProfile"
        return mode == .discharging && percentage < 10 && !usedLocalProfile
            ? total * Self.lowBatteryDamping
            : total
    }

    private func profileBaseMinutes(from start: Double, to end: Double, mode: Mode,
                                    bands: [BandObservation], segment: Int,
                                    date: Date? = nil) -> Double? {
        var position = start
        var total = 0.0
        while mode == .charging ? position < end : position > end {
            let lower = mode == .charging
                ? Int(floor(position / 5)) * 5 : Int(ceil(position / 5) - 1) * 5
            let next = mode == .charging
                ? min(end, Double(lower + 5)) : max(end, Double(lower))
            guard let baseline = bandMinutes(lower, in: bands, mode: mode,
                                             excluding: segment, now: date) else { return nil }
            total += baseline * abs(next - position) / 5
            position = next
        }
        return total > 0 ? total : nil
    }

    private func physicalChargeMinutes(from start: Double, to target: Double) -> Double? {
        guard let reference = chargingReferenceMinutesPerPoint else { return nil }
        return BatteryChargingModel.minutes(
            from: start,
            to: target,
            minutesPerPoint: reference
        )
    }

    private func effectiveBandMinutes(baseline: Double, distance: Double,
                                      from position: Double, start: Double,
                                      mode: Mode,
                                      baselineRateOverride: Double? = nil) -> Double {
        guard mode == .discharging,
              let recent = diagnostics.recentRate,
              recent > 0,
              let baselineRate = baselineRateOverride ?? diagnostics.baselineRate,
              baselineRate > 0 else {
            return baseline * distance / 5
        }
        let travelled = max(0, abs(position - start))
        let baseMinutesPerPoint = 1 / baselineRate
        let recentMinutesPerPoint = 1 / recent
        let stateWeight = dischargeStateMachine.weight(
            forDistance: travelled,
            horizon: dischargeStateMachine.state == .transient
                ? 2 : Self.dynamicHorizonPercent
        )
        let minutesPerPoint = baseMinutesPerPoint * (1 - stateWeight)
            + recentMinutesPerPoint * stateWeight
        return minutesPerPoint * distance
    }
}
