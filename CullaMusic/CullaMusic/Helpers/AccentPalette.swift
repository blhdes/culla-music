import SwiftUI

/// Palette colors are tuned for both light and dark themes — each swatch is
/// dark enough (lightness ≲ 0.55) that white text on a `.borderedProminent`
/// fill stays legible on a white background. Picking colors that "pop" on
/// dark theme but desaturate against white was the prior issue (neon green,
/// pale lavender, system mint).
///
/// `rawValue`s are stable AppStorage keys — don't rename cases. `neon` was
/// originally a near-white green; it's now retuned to a vivid amber that
/// reads against both backgrounds while keeping the "high-energy" slot.
enum AccentPalette: String, CaseIterable, Identifiable {
    case blue, coral, mint, lavender, neon
    case rose, crimson, plum, indigo, ocean, teal, emerald, sunset

    var id: String { rawValue }

    var label: String {
        switch self {
        case .blue:     "Sky"
        case .coral:    "Coral"
        case .mint:     "Mint"
        case .lavender: "Lavender"
        case .neon:     "Amber"
        case .rose:     "Rose"
        case .crimson:  "Crimson"
        case .plum:     "Plum"
        case .indigo:   "Indigo"
        case .ocean:    "Ocean"
        case .teal:     "Teal"
        case .emerald:  "Emerald"
        case .sunset:   "Sunset"
        }
    }

    var color: Color {
        switch self {
        case .blue:     .blue
        case .coral:    Color(red: 0.92, green: 0.40, blue: 0.42)
        case .mint:     Color(red: 0.20, green: 0.62, blue: 0.48)
        case .lavender: Color(red: 0.50, green: 0.42, blue: 0.82)
        case .neon:     Color(red: 0.93, green: 0.55, blue: 0.18)
        case .rose:     Color(red: 0.92, green: 0.48, blue: 0.62)
        case .crimson:  Color(red: 0.78, green: 0.20, blue: 0.30)
        case .plum:     Color(red: 0.58, green: 0.28, blue: 0.55)
        case .indigo:   Color(red: 0.32, green: 0.32, blue: 0.70)
        case .ocean:    Color(red: 0.15, green: 0.55, blue: 0.75)
        case .teal:     Color(red: 0.10, green: 0.55, blue: 0.55)
        case .emerald:  Color(red: 0.10, green: 0.55, blue: 0.35)
        case .sunset:   Color(red: 0.92, green: 0.42, blue: 0.22)
        }
    }
}
