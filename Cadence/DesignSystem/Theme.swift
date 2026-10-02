//
//  Theme.swift
//  Cadence
//
//  One place for colour, spacing and typography so the app looks like one app.
//  Colours are defined with light/dark variants and never carry meaning on their own
//  (accessibility rule: colour is always paired with an icon or a word).
//

import SwiftUI

enum Theme {

    // MARK: - Palette

    static let accent = Color(hex: "#5A6CF3")

    static let blockFill = Color(hex: "#5A6CF3")
    static let blockPinned = Color(hex: "#8E6CF3")
    static let blockImported = Color(hex: "#9AA0A6")

    static let priorityHigh = Color(hex: "#E5484D")
    static let priorityMedium = Color(hex: "#F79B45")
    static let priorityLow = Color(hex: "#4C9AFF")

    static let success = Color(hex: "#2FA36B")
    static let warning = Color(hex: "#E5A100")
    static let danger = Color(hex: "#E5484D")

    static func priorityColor(_ priority: TaskPriority) -> Color {
        switch priority {
        case .none: return .secondary
        case .low: return priorityLow
        case .medium: return priorityMedium
        case .high: return priorityHigh
        }
    }

    static func blockColor(for origin: BlockOrigin, isPinned: Bool, listColorHex: String?) -> Color {
        switch origin {
        case .imported: return blockImported
        case .user: return blockPinned
        case .auto:
            if isPinned { return blockPinned }
            if let listColorHex { return Color(hex: listColorHex) }
            return blockFill
        }
    }

    // MARK: - Spacing

    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
    }

    static let cornerRadius: CGFloat = 14
    static let blockCornerRadius: CGFloat = 8
}

// MARK: - Color from hex

extension Color {
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        let r, g, b, a: Double
        switch cleaned.count {
        case 3:
            r = Double((value >> 8) & 0xF) / 15
            g = Double((value >> 4) & 0xF) / 15
            b = Double(value & 0xF) / 15
            a = 1
        case 6:
            r = Double((value >> 16) & 0xFF) / 255
            g = Double((value >> 8) & 0xFF) / 255
            b = Double(value & 0xFF) / 255
            a = 1
        case 8:
            r = Double((value >> 24) & 0xFF) / 255
            g = Double((value >> 16) & 0xFF) / 255
            b = Double((value >> 8) & 0xFF) / 255
            a = Double(value & 0xFF) / 255
        default:
            r = 0.5; g = 0.5; b = 0.5; a = 1
        }
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}

// MARK: - Reusable surfaces

struct CardBackground: ViewModifier {
    var padding: CGFloat = Theme.Space.l

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
    }
}

extension View {
    func card(padding: CGFloat = Theme.Space.l) -> some View {
        modifier(CardBackground(padding: padding))
    }

    /// Accessibility helper: one VoiceOver sentence for an entire block cell.
    func blockAccessibilityLabel(title: String, start: Date, end: Date, detail: String?) -> some View {
        let base = "\(title), \(RelativeDateFormatter.time(start)) to \(RelativeDateFormatter.time(end))"
        return accessibilityLabel(detail.map { "\(base), \($0)" } ?? base)
    }
}
