import SwiftUI

/// Palette colors are free to be bright, saturated, or strange. Text laid *on
/// top of* an accent fill stays legible because the fill sites flip their
/// foreground by luminance — `Color.idealForeground` (the selected ModeTile)
/// and `Color.contrastingLabel` (the playlist chips) pick white on dark
/// swatches and near-black on light ones. So we no longer hand-restrain
/// lightness; we let the text color do the adapting.
///
/// One caveat the flip *doesn't* cover: when the accent is used as a plain
/// foreground tint on the app's light background (icons, accent-colored text),
/// a very pale swatch reads weakly in light mode. Keep new colors reasonably
/// saturated so they hold up as a tint, not just as a fill.
///
/// `rawValue`s are stable AppStorage keys — don't rename cases. `neon` was
/// originally a near-white green; it's now a vivid amber (kept under that key
/// to preserve anyone's saved pick) in the "high-energy" slot.
enum AccentPalette: String, CaseIterable, Identifiable {
    case blue, coral, mint, lavender, neon
    case rose, crimson, plum, indigo, ocean, teal, emerald, sunset
    // Second wave — stranger, earthier hues filling gaps the originals miss
    // (magenta, olive, rust, wine, slate, eggplant).
    case cobalt, fuchsia, wine, mulberry, grape, aubergine, mauve, slate
    case storm, forest, moss, olive, rust, raspberry, ochre
    // Third wave — the bright, electric end the old lightness cap used to
    // forbid. Legible on a fill because the label flips to dark; saturated
    // enough to still read as a tint.
    case chartreuse, aqua, lime, tangerine, flamingo

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
        case .cobalt:    "Cobalt"
        case .fuchsia:   "Fuchsia"
        case .wine:      "Wine"
        case .mulberry:  "Mulberry"
        case .grape:     "Grape"
        case .aubergine: "Aubergine"
        case .mauve:     "Mauve"
        case .slate:     "Slate"
        case .storm:     "Storm"
        case .forest:    "Forest"
        case .moss:      "Moss"
        case .olive:     "Olive"
        case .rust:      "Rust"
        case .raspberry: "Raspberry"
        case .ochre:     "Ochre"
        case .chartreuse: "Chartreuse"
        case .aqua:       "Aqua"
        case .lime:       "Lime"
        case .tangerine:  "Tangerine"
        case .flamingo:   "Flamingo"
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
        case .cobalt:    Color(red: 0.18, green: 0.30, blue: 0.78) // electric deep blue
        case .fuchsia:   Color(red: 0.85, green: 0.18, blue: 0.55) // vivid magenta
        case .wine:      Color(red: 0.50, green: 0.13, blue: 0.24) // deep burgundy
        case .mulberry:  Color(red: 0.56, green: 0.18, blue: 0.42) // purple-red berry
        case .grape:     Color(red: 0.40, green: 0.18, blue: 0.62) // deep violet
        case .aubergine: Color(red: 0.34, green: 0.16, blue: 0.36) // dusky eggplant
        case .mauve:     Color(red: 0.62, green: 0.40, blue: 0.56) // dusty rose-purple
        case .slate:     Color(red: 0.32, green: 0.42, blue: 0.54) // muted blue-gray
        case .storm:     Color(red: 0.28, green: 0.34, blue: 0.46) // dark steel blue
        case .forest:    Color(red: 0.13, green: 0.42, blue: 0.24) // deep pine green
        case .moss:      Color(red: 0.48, green: 0.56, blue: 0.16) // dark chartreuse
        case .olive:     Color(red: 0.45, green: 0.42, blue: 0.16) // dusty yellow-brown
        case .rust:      Color(red: 0.70, green: 0.32, blue: 0.16) // burnt orange
        case .raspberry: Color(red: 0.78, green: 0.16, blue: 0.42) // tart magenta-red
        case .ochre:     Color(red: 0.72, green: 0.50, blue: 0.16) // earthy gold
        case .chartreuse: Color(red: 0.66, green: 0.82, blue: 0.16) // electric yellow-green
        case .aqua:       Color(red: 0.12, green: 0.78, blue: 0.80) // bright cyan
        case .lime:       Color(red: 0.40, green: 0.80, blue: 0.28) // vivid grass green
        case .tangerine:  Color(red: 1.00, green: 0.54, blue: 0.12) // hot orange
        case .flamingo:   Color(red: 0.98, green: 0.42, blue: 0.60) // bright pink
        }
    }
}
