import SwiftUI

/// The one main action. Keeps its colour even when the panel is not focused, unlike the system prominent style.
struct PrimaryButtonStyle: ButtonStyle {
    var isCompact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(isCompact ? .system(size: 12, weight: .semibold) : .body.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, isCompact ? 10 : 14)
            .padding(.vertical, isCompact ? 3 : 6)
            .background(Color.accentColor.opacity(configuration.isPressed ? 0.75 : 1), in: Capsule())
    }
}

struct IconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.primary)
            .frame(width: 30, height: 28)
            .background(
                Color.primary.opacity(configuration.isPressed ? 0.16 : 0.07),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
    }
}
