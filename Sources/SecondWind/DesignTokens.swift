import AppKit
import SwiftUI

/// Second Wind's native translation of the Astryx tokens: semantic colours, a 4-point spacing
/// scale, three radii and three motion durations. Views use these names, never raw values.
enum SW {
    enum Palette {
        /// Brand teal. Primary actions, healthy headroom and the menu bar mark.
        static let accent = adaptive(light: 0x0E9F8E, dark: 0x3FD9C3)
        /// Near a limit. Never decorative.
        static let caution = adaptive(light: 0xB7791F, dark: 0xE0A53B)
        /// Needs the user: signed out, mismatched account, failed check.
        static let critical = adaptive(light: 0xD4553F, dark: 0xF0715F)
        static let canvas = adaptive(light: 0xF4F4F2, dark: 0x1B1B1B)
        static let surface = adaptive(light: 0xFFFFFF, dark: 0x262626)
        static let surfaceRaised = adaptive(light: 0xEDEDEA, dark: 0x303030)
        static let hairline = adaptive(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.08, darkAlpha: 0.08)
        static let track = adaptive(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.08, darkAlpha: 0.10)
        static let textPrimary = adaptive(light: 0x171717, dark: 0xFAFAFA)
        static let textSecondary = adaptive(light: 0x5C5C5C, dark: 0xB4B4B4)
        static let textTertiary = adaptive(light: 0x7A7A7A, dark: 0x8F8F8F)
        static let onAccent = adaptive(light: 0xFFFFFF, dark: 0x0B1F1C)

        private static func adaptive(
            light: UInt32,
            dark: UInt32,
            lightAlpha: CGFloat = 1,
            darkAlpha: CGFloat = 1
        ) -> Color {
            Color(nsColor: NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                let value = isDark ? dark : light
                return NSColor(
                    srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                    green: CGFloat((value >> 8) & 0xFF) / 255,
                    blue: CGFloat(value & 0xFF) / 255,
                    alpha: isDark ? darkAlpha : lightAlpha
                )
            })
        }
    }

    enum Space {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 20
    }

    enum Radius {
        static let small: CGFloat = 8
        static let medium: CGFloat = 12
        static let large: CGFloat = 16
    }

    enum Motion {
        static let quick = 0.175
        static let standard = 0.28
        static let slow = 0.41

        /// Exponential ease-out; no motion at all when Reduce Motion is on.
        static func easeOut(_ duration: Double, reduceMotion: Bool) -> Animation? {
            reduceMotion ? nil : .timingCurve(0.16, 1, 0.3, 1, duration: duration)
        }
    }

    enum Size {
        static let popoverWidth: CGFloat = 380
        static let popoverHeight: CGFloat = 560
        static let meterHeight: CGFloat = 6
    }
}

/// The tone a status carries. Colour is always paired with an icon and text.
enum SWTone: Equatable {
    case neutral
    case good
    case caution
    case critical

    var color: Color {
        switch self {
        case .neutral: SW.Palette.textSecondary
        case .good: SW.Palette.accent
        case .caution: SW.Palette.caution
        case .critical: SW.Palette.critical
        }
    }
}
