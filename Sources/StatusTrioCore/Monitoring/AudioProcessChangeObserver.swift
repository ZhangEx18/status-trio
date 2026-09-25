import AppKit
import CoreAudio

@MainActor
protocol AudioProcessChangeObserving: AnyObject {
    func start(onChange: @escaping @MainActor () -> Void)
    func stop()
}

/// The token owns only listener teardown. It is created/removed on MainActor;
/// deinit can safely unregister the captured immutable HAL address and block.
private final class AudioProcessListenerToken: @unchecked Sendable {
    let objectID: AudioObjectID
    let address: AudioObjectPropertyAddress
    let block: AudioObjectPropertyListenerBlock

    init?(objectID: AudioObjectID, selector: AudioObjectPropertySelector,
          block: @escaping AudioObjectPropertyListenerBlock) {
        self.objectID = objectID
        self.address = AudioObjectPropertyAddress(mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        self.block = block
        var address = self.address
        guard AudioObjectAddPropertyListenerBlock(objectID, &address, .main, block) == noErr else { return nil }
    }

    deinit {
        var address = address
        _ = AudioObjectRemovePropertyListenerBlock(objectID, &address, .main, block)
    }
}

private final class AudioWorkspaceListenerToken: @unchecked Sendable {
    let center: NotificationCenter
    let token: NSObjectProtocol
    init(center: NotificationCenter, name: Notification.Name, callback: @escaping @Sendable () -> Void) {
        self.center = center
        self.token = center.addObserver(forName: name, object: nil, queue: .main) { _ in callback() }
    }
    deinit { center.removeObserver(token) }
}

@MainActor
final class CoreAudioProcessChangeObserver: AudioProcessChangeObserving {
    private var listListener: AudioProcessListenerToken?
    private var processListeners: [AudioObjectID: AudioProcessListenerToken] = [:]
    private var workspaceListeners: [AudioWorkspaceListenerToken] = []
    private var onChange: (@MainActor () -> Void)?

    func start(onChange: @escaping @MainActor () -> Void) {
        stop()
        self.onChange = onChange
        listListener = AudioProcessListenerToken(objectID: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyProcessObjectList) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.changed() }
            }
        let center = NSWorkspace.shared.notificationCenter
        workspaceListeners = [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification].map { name in
            AudioWorkspaceListenerToken(center: center, name: name) { [weak self] in
                Task { @MainActor [weak self] in self?.changed() }
            }
        }
        reconcileProcesses()
    }

    func stop() {
        onChange = nil
        listListener = nil
        processListeners.removeAll()
        workspaceListeners.removeAll()
    }

    private func changed() {
        guard onChange != nil else { return }
        reconcileProcesses()
        onChange?()
    }

    private func reconcileProcesses() {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.stride)
        if !objects.isEmpty {
            let result = objects.withUnsafeMutableBytes { bytes in
                AudioObjectGetPropertyData(system, &address, 0, nil, &size, bytes.baseAddress!)
            }
            guard result == noErr else { return }
            objects = Array(objects.prefix(Int(size) / MemoryLayout<AudioObjectID>.stride))
        }
        let current = Set(objects)
        processListeners = processListeners.filter { current.contains($0.key) }
        for objectID in current where processListeners[objectID] == nil {
            processListeners[objectID] = AudioProcessListenerToken(objectID: objectID,
                selector: kAudioProcessPropertyIsRunningOutput) { [weak self] _, _ in
                    Task { @MainActor [weak self] in self?.changed() }
                }
        }
    }
}
