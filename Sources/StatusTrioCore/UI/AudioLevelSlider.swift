import SwiftUI

/// Compact audio track with a larger hit area and keyboard/VoiceOver adjustment.
struct AudioLevelSlider: View {
    @Binding var value: Double
    var onEditingChanged: (Bool) -> Void = { _ in }
    @Environment(\.isEnabled) private var isEnabled
    @State private var isDragging = false
    @State private var isHovered = false

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.16)).frame(height: 4)
                Capsule().fill(Color.accentColor)
                    .frame(width: geometry.size.width * min(1, max(0, value)), height: 4)
                if isDragging || isHovered {
                    Circle().fill(.white).frame(width: 10, height: 10)
                        .offset(x: max(0, (geometry.size.width - 10) * min(1, max(0, value))))
                }
            }
            .frame(height: 24)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { event in
                    guard isEnabled, geometry.size.width > 0 else { return }
                    if !isDragging {
                        isDragging = true
                        onEditingChanged(true)
                    }
                    value = min(1, max(0, event.location.x / geometry.size.width))
                }
                .onEnded { _ in
                    isDragging = false
                    onEditingChanged(false)
                })
        }
        .frame(height: 24)
        .opacity(isEnabled ? 1 : 0.4)
        .onHover { isHovered = $0 }
        .accessibilityElement()
        .accessibilityValue(value.formatted(.percent.precision(.fractionLength(0))))
        .accessibilityAdjustableAction { direction in
            guard isEnabled else { return }
            switch direction {
            case .increment: value = min(1, value + 0.05)
            case .decrement: value = max(0, value - 0.05)
            @unknown default: break
            }
        }
        .focusable(isEnabled)
        .onKeyPress(.leftArrow) { guard isEnabled else { return .ignored }; value = max(0, value - 0.05); return .handled }
        .onKeyPress(.rightArrow) { guard isEnabled else { return .ignored }; value = min(1, value + 0.05); return .handled }
    }
}
