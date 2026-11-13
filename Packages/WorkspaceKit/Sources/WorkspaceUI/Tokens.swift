import SwiftUI

// Design tokens from DESIGN.md §3. Dark is the default look; light mirrors it.
// Rule of thumb: chrome stays neutral; the only saturated color comes from
// container colors (ContainerColor) and the two accents below.

public enum WSColor {
    public static let canvas    = Color.dynamic(light: 0xFFFFFF, dark: 0x191919)
    public static let weekend   = Color.dynamic(light: 0xF7F7F5, dark: 0x1E1E1E)
    public static let raised    = Color.dynamic(light: 0xFFFFFF, dark: 0x232323)
    public static let hairline  = Color.dynamic(light: 0xE9E9E7, dark: 0x2A2A2A)

    public static let textPrimary   = Color.dynamic(light: 0x1F1F1F, dark: 0xEDEDED)
    public static let textSecondary = Color.dynamic(light: 0x6B6B6B, dark: 0x9B9B9B)
    public static let textTertiary  = Color.dynamic(light: 0x9B9B9B, dark: 0x6B6B6B)

    /// Current-time line, today badge.
    public static let now    = Color(hex: 0xE5484D)
    /// Primary button, focus ring.
    public static let action = Color(hex: 0x2F81F7)
}

/// Container colors. `accent` is the left bar / checkbox; `fill` is the block background.
public enum ContainerColor: String, CaseIterable, Identifiable, Sendable {
    case plum, violet, green, rust, steel, gold, rose, grey

    public var id: String { rawValue }

    public init(named name: String) {
        self = ContainerColor(rawValue: name) ?? .grey
    }

    public var accent: Color {
        switch self {
        case .plum:   Color(hex: 0xB65FD1)
        case .violet: Color(hex: 0x8B7BE0)
        case .green:  Color(hex: 0x4FA66A)
        case .rust:   Color(hex: 0xE07A45)
        case .steel:  Color(hex: 0x5AA9E6)
        case .gold:   Color(hex: 0xD6A740)
        case .rose:   Color(hex: 0xE0607E)
        case .grey:   Color(hex: 0x8A8A8A)
        }
    }

    public var fill: Color {
        switch self {
        case .plum:   .dynamic(light: 0xF4E8F8, dark: 0x4A3550)
        case .violet: .dynamic(light: 0xECE9FB, dark: 0x3F3A63)
        case .green:  .dynamic(light: 0xE5F3E9, dark: 0x2C4433)
        case .rust:   .dynamic(light: 0xFBEDE5, dark: 0x5E3524)
        case .steel:  .dynamic(light: 0xE6F2FB, dark: 0x2B3F50)
        case .gold:   .dynamic(light: 0xF9F1DE, dark: 0x4D4126)
        case .rose:   .dynamic(light: 0xFBE8EC, dark: 0x55303A)
        case .grey:   .dynamic(light: 0xEFEFED, dark: 0x3A3A3A)
        }
    }

    public var displayName: String { rawValue.capitalized }

    /// Accent as 0xRRGGBB (for calendar color overrides).
    public var hex: UInt32 {
        switch self {
        case .plum: 0xB65FD1
        case .violet: 0x8B7BE0
        case .green: 0x4FA66A
        case .rust: 0xE07A45
        case .steel: 0x5AA9E6
        case .gold: 0xD6A740
        case .rose: 0xE0607E
        case .grey: 0x8A8A8A
        }
    }
}

public enum WSSpace {
    public static let xxs: CGFloat = 2
    public static let xs: CGFloat = 4
    public static let s: CGFloat = 8
    public static let m: CGFloat = 12
    public static let l: CGFloat = 16
    public static let xl: CGFloat = 24
    public static let xxl: CGFloat = 32
}

public enum WSRadius {
    /// Calendar blocks, board cards.
    public static let block: CGFloat = 6
    /// Popovers, sheets.
    public static let popover: CGFloat = 8
    /// Left accent bar width on blocks.
    public static let accentBar: CGFloat = 3
}

public enum WSFont {
    public static let blockTitle = Font.system(size: 12, weight: .medium)
    public static let blockMeta  = Font.system(size: 11).monospacedDigit()
    public static let body       = Font.system(size: 13)
    public static let rowTitle   = Font.system(size: 13, weight: .regular)
    public static let sectionLabel = Font.system(size: 11, weight: .semibold)
    public static let pageTitle  = Font.system(size: 22, weight: .bold)
    public static let metric     = Font.system(size: 12).monospacedDigit()
}

// MARK: - Color helpers

extension Color {
    public init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }

    /// A color that follows the system light/dark appearance.
    public static func dynamic(light: UInt32, dark: UInt32) -> Color {
        #if canImport(UIKit)
        Color(UIColor { traits in
            UIColor(Color(hex: traits.userInterfaceStyle == .dark ? dark : light))
        })
        #elseif canImport(AppKit)
        Color(NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(Color(hex: isDark ? dark : light))
        })
        #endif
    }
}
