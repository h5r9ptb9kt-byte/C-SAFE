//
//  Theme.swift — C-SAFE
//  Couleurs du logo C-FOCUS : bleu nuit, orange coucher de soleil, cyan, crème.
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

    static let sunset = LinearGradient(colors: [orange, orangeDark], startPoint: .top, endPoint: .bottom)
}

/// Encadré de section (« carte » de l'interface)
struct Panel<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(Theme.orange)
                Text(title.uppercased())
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .tracking(1.2)
                    .foregroundStyle(Theme.muted)
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Theme.stroke, lineWidth: 1))
    }
}

struct FieldLabel: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Theme.muted)
    }
}

extension View {
    /// Aspect « champ » commun aux saisies et menus
    func fieldLook() -> some View {
        self
            .padding(.horizontal, 12)
            .frame(minHeight: 40)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.field))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.stroke, lineWidth: 1))
    }
}

/// Gros bouton orange (action principale)
struct PrimaryButtonStyle: ButtonStyle {
    var color: Color = Theme.orange
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .bold, design: .rounded))
            .foregroundStyle(Color(hex: 0x1A0F06))
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(color))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

/// Bouton secondaire (contour)
struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold, design: .rounded))
            .foregroundStyle(Theme.cream)
            .padding(.horizontal, 14)
            .frame(minHeight: 40)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.field))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.stroke, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}
