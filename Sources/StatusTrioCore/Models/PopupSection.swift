import Foundation

enum PopupSection: String, CaseIterable, Identifiable, Sendable {
    case battery
    case network
    case volume

    var id: Self { self }

    var titleKey: LocalizationKey {
        switch self {
        case .battery: .settingsPopupOrderBattery
        case .network: .networkTitle
        case .volume: .settingsPopupOrderVolume
        }
    }

    var systemImage: String {
        switch self {
        case .battery: "battery.100percent"
        case .network: "wifi"
        case .volume: "speaker.wave.2"
        }
    }
}
