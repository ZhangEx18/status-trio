import AppKit
import Combine
import CoreGraphics

/// The state of macOS's Screen & System Audio Recording permission.
enum AudioCapturePermissionStatus: Equatable, Sendable {
    case unknown
    case authorized
    case denied
}

/// Owns the public permission flow required before creating a Core Audio process tap.
///
/// The controller deliberately does not use TCC private APIs. A failed tap creation
/// can leave the state at `unknown` and the UI can send the user to System Settings.
@MainActor
final class AudioCapturePermissionController: ObservableObject {
    nonisolated static let systemSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
    )!

    @Published private(set) var status: AudioCapturePermissionStatus

    private let preflight: () -> Bool
    private let requestAccess: () -> Bool
    private let openSettings: () -> Bool

    init(
        preflight: @escaping () -> Bool = {
            CGPreflightScreenCaptureAccess()
        },
        requestAccess: @escaping () -> Bool = {
            CGRequestScreenCaptureAccess()
        },
        openSettings: @escaping () -> Bool = {
            NSWorkspace.shared.open(AudioCapturePermissionController.systemSettingsURL)
        }
    ) {
        self.preflight = preflight
        self.requestAccess = requestAccess
        self.openSettings = openSettings
        self.status = .unknown
        refresh()
    }

    func refresh() {
        if preflight() {
            status = .authorized
        } else if status != .denied {
            status = .unknown
        }
    }

    @discardableResult
    func request() -> Bool {
        let granted = requestAccess()
        status = granted ? .authorized : .denied
        return granted
    }

    @discardableResult
    func openSystemSettings() -> Bool {
        openSettings()
    }
}
