import SwiftUI

/// Values measured from sing-vpn-interface.sketch, “Превью / VPN”.
enum PrototypeStyle {
    static let accent = Color(red: 166 / 255, green: 22 / 255, blue: 67 / 255)
    static let background = Color(red: 255 / 255, green: 252 / 255, blue: 253 / 255)
    static let secondary = Color(red: 142 / 255, green: 142 / 255, blue: 147 / 255)
    static let separator = Color(red: 235 / 255, green: 235 / 255, blue: 235 / 255)
    static let border = Color(red: 237 / 255, green: 211 / 255, blue: 221 / 255)
    static let field = Color(red: 242 / 255, green: 242 / 255, blue: 247 / 255)
}

struct PrototypePillStyle: ButtonStyle {
    var filled = false
    var onArtwork = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 16)
            .frame(minHeight: filled ? 50 : 28)
            .background(filled ? PrototypeStyle.accent : (onArtwork ? Color.white.opacity(0.24) : .clear), in: Capsule())
            .foregroundStyle(filled || onArtwork ? .white : PrototypeStyle.accent)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.65 : 1)
    }
}

extension View {
    func prototypeSurface(radius: CGFloat = 24) -> some View {
        background(.white, in: RoundedRectangle(cornerRadius: radius))
            .overlay { RoundedRectangle(cornerRadius: radius).strokeBorder(PrototypeStyle.border, lineWidth: 1) }
            .shadow(color: Color(red: 0.35, green: 0.08, blue: 0.18).opacity(0.08), radius: 8, y: 4)
    }
}

/// Preserve the explicit disabled appearance from the source instead of dimming it twice.
struct PrototypeFlatStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.65 : 1)
    }
}
