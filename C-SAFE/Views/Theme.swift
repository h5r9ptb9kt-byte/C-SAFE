//
//  Theme.swift — C-SAFE
//  Couleurs du logo C-FOCUS : bleu nuit, orange coucher de soleil, cyan, crème.
//  Interface compacte : la fenêtre peut rester dans un coin du bureau.
//

import SwiftUI

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}

enum Theme {
    /// Sur iPhone / iPad, textes et zones de toucher plus grands (doigt, pas souris)
    #if os(iOS)
    static let scale: CGFloat = 1.22
    #else
    static let scale: CGFloat = 1
    #endif
    static func fs(_ size: CGFloat) -> CGFloat { (size * scale).rounded() }

    static let background = Color(hex: 0x0F1924)
    static let panel = Color(hex: 0x172636)
    static let field = Color(hex: 0x1D2D40)
    static let stroke = Color(hex: 0x2B4058)
    static let cream = Color(hex: 0xF1EAD6)
    static let muted = Color(hex: 0x8FA6BD)
    static let orange = Color(hex: 0xE8742A)
    static let orangeDark = Color(hex: 0xC85A1C)
    static let cyan = Color(hex: 0x2A9FD6)
    static let green = Color(hex: 0x3CCB8F)
    static let red = Color(hex: 0xE5534B)
}

/// Encadré de section, compact
struct Panel<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: Theme.fs(10), weight: .bold))
                    .foregroundStyle(Theme.orange)
                Text(title.uppercased())
                    .font(.system(size: Theme.fs(10), weight: .bold, design: .rounded))
                    .tracking(1)
                    .foregroundStyle(Theme.muted)
            }
            content
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.stroke, lineWidth: 1))
    }
}

struct FieldLabel: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: Theme.fs(10), weight: .medium))
            .foregroundStyle(Theme.muted)
    }
}

extension View {
    /// Aspect « champ » commun aux saisies et menus
    func fieldLook() -> some View {
        self
            .padding(.horizontal, 8)
            .frame(minHeight: Theme.fs(28))
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.field))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(Theme.stroke, lineWidth: 1))
    }
}

/// Bouton principal
struct PrimaryButtonStyle: ButtonStyle {
    var color: Color = Theme.orange
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: Theme.fs(14), weight: .bold, design: .rounded))
            .foregroundStyle(Color(hex: 0x1A0F06))
            .frame(maxWidth: .infinity, minHeight: Theme.fs(34) + (Theme.scale > 1 ? 8 : 0))
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(color))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

/// Bouton secondaire (contour)
struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: Theme.fs(12), weight: .semibold, design: .rounded))
            .foregroundStyle(Theme.cream)
            .padding(.horizontal, 9)
            .frame(minHeight: Theme.fs(26) + (Theme.scale > 1 ? 6 : 0))
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.field))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(Theme.stroke, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}
