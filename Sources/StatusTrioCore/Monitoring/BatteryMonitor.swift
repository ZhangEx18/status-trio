import ChargeLimit
import AppKit
import Foundation
import IOKit.ps
import OSLog

private let batteryMonitorLogger = Logger(
    subsystem: "com.lingsmbp.StatusTrio",
    category: "battery"
)

struct BatteryReading: Equatable, Sendable {
    var currentCapacity: Int
    var maxCapacity: Int
    var isCharging: Bool
    var isCharged: Bool = false
    var timeToFullChargeMinutes: Int? = nil
    var remainingMinutes: Int? = nil
    var chargeLimit: Int? = nil
    var chargeLimitKnown = false
    var isConnectedToPower: Bool
    var isPresent: Bool
}

protocol BatteryReadingProviding: AnyObject {
    func read() -> BatteryReading?
}

typealias IOPSNotificationCallback = @convention(c) (UnsafeMutableRawPointer?) -> Void
typealias IOPSRunLoopSourceFactory = (
    UnsafeMutableRawPointer?,
    IOPSNotificationCallback
) -> CFRunLoopSource?

private final class BatteryCallbackContext: @unchecked Sendable {
    weak var monitor: BatteryMonitor?

    init(monitor: BatteryMonitor) {
        self.monitor = monitor
    }
}

private struct BatteryEstimatorContext: Sendable {
    let date: Date
    let percentage: Double
    let mode: BatteryDataCleaner.Mode?
    let chargeTarget: Double?
    let systemEstimateMinutes: Int?
    let lowPowerMode: Bool?
    let maximumCapacity: Int?
}

private struct BatteryEstimatorForecasts: Sendable {
    let profile: Int?
    let legacy: Int?
}

final class IOPSBatteryReader: BatteryReadingProviding {
    func read() -> BatteryReading? {
        guard
            let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }

        for source in sources {
            guard
                let description = IOPSGetPowerSourceDescription(snapshot, source)?
                    .takeUnretainedValue() as? [String: Any],
                var reading = Self.parse(description)
            else { continue }

            let limit = STReadChargeLimit()
            reading.chargeLimitKnown = limit >= 0
            reading.chargeLimit = limit > 0 ? Int(limit) : nil
            return reading
        }

        return nil
    }

    static func parse(_ description: [String: Any]) -> BatteryReading? {
        guard description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else {
            return nil
        }
        guard
            let current = integerValue(description[kIOPSCurrentCapacityKey]),
            let maximum = integerValue(description[kIOPSMaxCapacityKey])
        else { return nil }
        guard current >= 0, maximum >= 0, maximum == 0 || current <= maximum else { return nil }

        let rawTimeToFullCharge = integerValue(description[kIOPSTimeToFullChargeKey])
        let timeToFullCharge = rawTimeToFullCharge.flatMap { $0 > 0 ? $0 : nil }

        return BatteryReading(
            currentCapacity: current,
            maxCapacity: maximum,
            isCharging: description[kIOPSIsChargingKey] as? Bool ?? false,
            isCharged: description[kIOPSIsChargedKey] as? Bool ?? false,
            timeToFullChargeMinutes: timeToFullCharge,
            remainingMinutes: integerValue(description[kIOPSTimeToEmptyKey]).flatMap { $0 > 0 ? $0 : nil },
            isConnectedToPower: description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue,
            isPresent: description[kIOPSIsPresentKey] as? Bool ?? true
        )
    }

    private static func integerValue(_ rawCapacity: Any?) -> Int? {
        guard let number = rawCapacity as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              !["f", "d"].contains(String(cString: number.objCType)) else { return nil }
        return Int(exactly: number.doubleValue)
    }
}

@MainActor
final class BatteryMonitor: BatteryMonitoring {
    private enum Lifecycle {
        case idle
        case running
        case stopped
    }

    let updates: AsyncStream<BatteryStatus>
    private let continuation: AsyncStream<BatteryStatus>.Continuation
    private let reader: any BatteryReadingProviding
    private let lowPowerModeProvider: () -> Bool
    private let nowProvider: () -> Date
    private let defaults: UserDefaults
    private let notificationCenter: NotificationCenter
    private let workspaceNotificationCenter: NotificationCenter
    private let profileStore: BatteryTimeProfileStore
    private let sampleStore: BatterySampleFileStore
    private var profileCatalog = BatteryTimeProfileCatalog()
    private let iopsRunLoopSourceFactory: IOPSRunLoopSourceFactory
    nonisolated(unsafe) private var runLoopSource: CFRunLoopSource?
    nonisolated(unsafe) private var lowPowerObserver: NSObjectProtocol?
    nonisolated(unsafe) private var sleepObserver: NSObjectProtocol?
    nonisolated(unsafe) private var wakeObserver: NSObjectProtocol?
    nonisolated(unsafe) private var callbackContext: Unmanaged<BatteryCallbackContext>?
    private var lifecycle = Lifecycle.idle
    private var timeEstimator = BatteryTimeEstimator()
    private var legacyTimeEstimator = BatteryTimeEstimator()
    private var lastProfileCaptureKey: String?
    private var chargingPauseSince: Date?
    private var chargingPauseState = false
    private let telemetryRecorder: BatteryTelemetryRecorder?

    init(
        reader: any BatteryReadingProviding = IOPSBatteryReader(),
        lowPowerModeProvider: @escaping () -> Bool = {
            ProcessInfo.processInfo.isLowPowerModeEnabled
        },
        nowProvider: @escaping () -> Date = Date.init,
        defaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = .default,
        workspaceNotificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        telemetryRecorder: BatteryTelemetryRecorder? = nil,
        sampleStoreDirectory: URL? = nil,
        iopsRunLoopSourceFactory: @escaping IOPSRunLoopSourceFactory = { context, callback in
            IOPSNotificationCreateRunLoopSource(callback, context)?.takeRetainedValue()
        }
    ) {
        self.reader = reader
        self.lowPowerModeProvider = lowPowerModeProvider
        self.nowProvider = nowProvider
        self.defaults = defaults
        self.notificationCenter = notificationCenter
        self.workspaceNotificationCenter = workspaceNotificationCenter
        let profileStore = BatteryTimeProfileStore(defaults: defaults)
        self.profileStore = profileStore
        let now = nowProvider()
        let sampleStore = sampleStoreDirectory.map {
            BatterySampleFileStore(directory: $0, defaults: defaults)
        } ?? BatterySampleFileStore(defaults: defaults)
        self.sampleStore = sampleStore
        let restored = sampleStore.load()
        var profileCatalog = (try? profileStore.loadOrRebuild(samples: restored, now: now))
            ?? BatteryTimeProfileCatalog()
        let storedProfiles = profileCatalog
        _ = profileCatalog.pruneExpired(now: now)
        for profile in BatteryTimeProfileBuilder.completeProfiles(from: restored).profiles {
            _ = profileCatalog.addIfNewer(profile, now: now)
        }
        if profileCatalog != storedProfiles { profileStore.save(profileCatalog) }
        self.profileCatalog = profileCatalog
        let activeProfiles = profileCatalog.hasBidirectionalProfiles(now: now)
            ? profileCatalog : BatteryTimeProfileCatalog()
        self.timeEstimator = BatteryTimeEstimator(profiles: activeProfiles)
        self.legacyTimeEstimator = BatteryTimeEstimator()
        self.telemetryRecorder = telemetryRecorder ?? (reader is IOPSBatteryReader
            ? BatteryTelemetryRecorder() : nil)
        timeEstimator.restore(restored, now: now)
        legacyTimeEstimator.restore(restored, now: now)
        self.iopsRunLoopSourceFactory = iopsRunLoopSourceFactory
        (updates, continuation) = MonitorStream.make(of: BatteryStatus.self)
    }

    deinit {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)
        }
        if let lowPowerObserver {
            notificationCenter.removeObserver(lowPowerObserver)
        }
        if let sleepObserver {
            workspaceNotificationCenter.removeObserver(sleepObserver)
        }
        if let wakeObserver {
            workspaceNotificationCenter.removeObserver(wakeObserver)
        }
        if let callbackContext {
            callbackContext.release()
        }
        continuation.finish()
    }

    func start() {
        guard lifecycle == .idle else { return }
        lifecycle = .running

        installNotifications()
        refresh()
    }

    func recover() {
        guard lifecycle == .running else { return }

        // Wake recovery must never let the last pre-sleep sample pair with the
        // first post-wake sample.  Historical observations stay available to
        // the baseline, while the live interval starts from scratch.
        timeEstimator.markDirtyInterval()
        legacyTimeEstimator.markDirtyInterval()
        teardownNotifications()
        installNotifications()
    }

    private func installNotifications() {

        let context = Unmanaged.passRetained(BatteryCallbackContext(monitor: self))
        callbackContext = context

        let callback: IOPSNotificationCallback = { contextPointer in
            guard let contextPointer else { return }
            let callbackContext = Unmanaged<BatteryCallbackContext>
                .fromOpaque(contextPointer)
                .takeUnretainedValue()
            guard let monitor = callbackContext.monitor else { return }
            Task { @MainActor in
                monitor.refresh()
            }
        }

        if let source = iopsRunLoopSourceFactory(context.toOpaque(), callback) {
            runLoopSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        } else {
            batteryMonitorLogger.error(
                "IOPS notification source unavailable; fallback refresh remains active"
            )
        }

        lowPowerObserver = notificationCenter.addObserver(
            forName: .NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }

        sleepObserver = workspaceNotificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.timeEstimator.markDirtyInterval()
                self?.legacyTimeEstimator.markDirtyInterval()
            }
        }

        wakeObserver = workspaceNotificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.timeEstimator.markDirtyInterval()
                self?.legacyTimeEstimator.markDirtyInterval()
            }
        }
    }

    func stop() {
        guard lifecycle != .stopped else { return }
        lifecycle = .stopped
        teardownNotifications()
        continuation.finish()
    }

    func refresh() {
        guard lifecycle != .stopped else { return }

        let reading = reader.read()
        let now = nowProvider()
        let previousSampleDate = timeEstimator.persistedSamples.last?.date
        let status: BatteryStatus

        if let reading, reading.isPresent {
            let cleaned = BatteryDataCleaner.clean(
                currentCapacity: reading.currentCapacity,
                maxCapacity: reading.maxCapacity,
                connectedToPower: reading.isConnectedToPower,
                charging: reading.isCharging,
                isPresent: reading.isPresent
            )
            let exactPercentage = cleaned?.percentage ?? 0
            if reading.isConnectedToPower && !reading.isCharging {
                if chargingPauseSince == nil { chargingPauseSince = now }
                let nearLimit = reading.chargeLimit.map { exactPercentage >= Double($0 - 3) } ?? false
                chargingPauseState = nearLimit && now.timeIntervalSince(chargingPauseSince!) >= 120
            } else {
                chargingPauseSince = nil
                chargingPauseState = false
            }
            let percentage = Int(exactPercentage.rounded())
            let reachedLimit = reading.isConnectedToPower && !reading.isCharging
                && reading.chargeLimit.map { abs(percentage - $0) <= 3 } == true
            let chargingTarget = reading.isCharging && (reading.chargeLimitKnown || reading.chargeLimit != nil)
                ? Double(reading.chargeLimit ?? 100) : nil
            let forecasts = calculateEstimates(BatteryEstimatorContext(
                date: now,
                percentage: exactPercentage,
                mode: chargingPauseState ? nil : cleaned?.mode,
                chargeTarget: chargingTarget,
                systemEstimateMinutes: reading.isCharging
                    ? reading.timeToFullChargeMinutes : reading.remainingMinutes,
                lowPowerMode: lowPowerModeProvider(),
                maximumCapacity: reading.maxCapacity
            ))
            let profileEstimate = forecasts.profile
            let legacyEstimate = forecasts.legacy
            let completedChargeProfile = reading.isConnectedToPower
                && reading.chargeLimit.map { exactPercentage >= Double($0) } == true
            let completedDischargeProfile = !reading.isConnectedToPower
                && !reading.isCharging && exactPercentage <= 5
            if completedChargeProfile || completedDischargeProfile {
                updateProfilesFromCompletedSamples(at: now)
            }
            if previousSampleDate != timeEstimator.persistedSamples.last?.date {
                persistEstimatorSamples()
            }
            let estimate = profileEstimate ?? legacyEstimate
            let selectedSource = selectedProfileDirection(
                for: reading, target: chargingTarget, profileEstimate: profileEstimate, at: now
            )
            status = BatteryStatus(
                rawPercentage: percentage,
                isPresent: true,
                isCharging: reading.isCharging,
                isCharged: reading.isCharged || reachedLimit,
                chargeLimit: reading.chargeLimit,
                timeToFullChargeMinutes: reading.isCharging
                    ? (estimate ?? reading.timeToFullChargeMinutes)
                    : nil,
                remainingMinutes: !reading.isConnectedToPower && !reading.isCharging
                    ? (estimate ?? reading.remainingMinutes) : nil,
                isLowPowerMode: lowPowerModeProvider(),
                isConnectedToPower: reading.isConnectedToPower
            )
            telemetryRecorder?.record(
                reading,
                at: now,
                estimatorMinutes: estimate,
                profileEstimatorMinutes: profileEstimate,
                legacyEstimatorMinutes: legacyEstimate,
                selectedEstimatorSource: selectedSource,
                displayedMinutes: reading.isCharging
                    ? status.timeToFullChargeMinutes : status.remainingMinutes,
                estimatorTargetPercent: chargingTarget,
                diagnostics: timeEstimator.diagnostics,
                boundaryReason: timeEstimator.persistedSamples.last?.boundaryReason?.rawValue,
                lowPowerMode: lowPowerModeProvider(),
                chargingPauseState: chargingPauseState,
                chargingPauseReason: chargingPauseState ? "nearLimitNoProgress" : nil
            )
        } else {
            timeEstimator.resetCurrentPrediction()
            legacyTimeEstimator.resetCurrentPrediction()
            if previousSampleDate != timeEstimator.persistedSamples.last?.date {
                persistEstimatorSamples()
            }
            status = BatteryStatus(
                rawPercentage: nil,
                isPresent: false,
                isCharging: false,
                isCharged: false,
                timeToFullChargeMinutes: nil,
                isLowPowerMode: lowPowerModeProvider(),
                isConnectedToPower: false
            )
        }

        continuation.yield(status)
    }

    private func updateProfilesFromCompletedSamples(at date: Date) {
        guard let newestSample = timeEstimator.persistedSamples.last else { return }
        let targetDescription = newestSample.target.map { String($0) } ?? "unknown"
        let key = "\(newestSample.mode)-\(targetDescription)-\(newestSample.segment)"
        guard key != lastProfileCaptureKey else { return }
        lastProfileCaptureKey = key

        var changed = false
        for profile in BatteryTimeProfileBuilder.latestCompleteProfiles(from: timeEstimator.persistedSamples).profiles {
            changed = profileCatalog.addIfNewer(profile, now: date) || changed
        }
        guard changed else { return }
        profileStore.save(profileCatalog)
        let activeProfiles = profileCatalog.hasBidirectionalProfiles(now: date)
            ? profileCatalog : BatteryTimeProfileCatalog()
        timeEstimator.updateProfiles(activeProfiles)
    }

    private func calculateEstimates(_ context: BatteryEstimatorContext) -> BatteryEstimatorForecasts {
        BatteryEstimatorForecasts(
            profile: estimate(using: &timeEstimator, context: context),
            legacy: estimate(using: &legacyTimeEstimator, context: context)
        )
    }

    private func estimate(using estimator: inout BatteryTimeEstimator,
                          context: BatteryEstimatorContext) -> Int? {
        switch context.mode {
        case .charging:
            return estimator.add(date: context.date, percentage: context.percentage,
                                 charging: true, target: context.chargeTarget,
                                 connectedToPower: true, systemMinutes: context.systemEstimateMinutes,
                                 lowPowerMode: context.lowPowerMode, maximumCapacity: context.maximumCapacity)
        case .discharging:
            return estimator.add(date: context.date, percentage: context.percentage,
                                 charging: false, target: 0, connectedToPower: false,
                                 systemMinutes: context.systemEstimateMinutes,
                                 lowPowerMode: context.lowPowerMode, maximumCapacity: context.maximumCapacity)
        case .mixedPower, .unavailable, .none:
            return estimator.add(date: context.date, percentage: context.percentage,
                                 charging: false, target: nil, connectedToPower: true)
        }
    }

    private func selectedProfileDirection(
        for reading: BatteryReading,
        target: Double?,
        profileEstimate: Int?,
        at date: Date
    ) -> String {
        guard profileEstimate != nil, profileCatalog.hasBidirectionalProfiles(now: date) else {
            return "legacy"
        }
        if reading.isCharging, let target {
            return profileCatalog.hasProfile(direction: .charging,
                                             targetPercent: Int(target.rounded()), now: date)
                ? "deviceProfile" : "legacy"
        }
        if !reading.isConnectedToPower && !reading.isCharging,
           profileCatalog.hasProfile(direction: .discharging,
                                     targetPercent: BatteryTimeProfile.profiledDischargeReservePercent,
                                     now: date) {
            return "deviceProfile"
        }
        return "legacy"
    }

    private func persistEstimatorSamples() {
        sampleStore.persist(timeEstimator.persistedSamples)
    }

    private func teardownNotifications() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)
            self.runLoopSource = nil
        }
        if let lowPowerObserver {
            notificationCenter.removeObserver(lowPowerObserver)
            self.lowPowerObserver = nil
        }
        if let sleepObserver {
            workspaceNotificationCenter.removeObserver(sleepObserver)
            self.sleepObserver = nil
        }
        if let wakeObserver {
            workspaceNotificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        if let callbackContext {
            callbackContext.release()
            self.callbackContext = nil
        }
    }
}
