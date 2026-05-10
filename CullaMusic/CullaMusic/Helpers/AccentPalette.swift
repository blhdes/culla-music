import SwiftUI

enum AccentPalette: String, CaseIterable, Identifiable {
    case blue, coral, mint, lavender, neon

    var id: String { rawValue }

    var label: String {
        switch self {
        case .blue:     "Sky"
        case .coral:    "Coral"
        case .mint:     "Mint"
        case .lavender: "Lavender"
        case .neon:     "Neon"
        }
    }

    var color: Color {
        switch self {
        case .blue:     .blue
        case .coral:    Color(red: 1.00, green: 0.42, blue: 0.42)
        case .mint:     .mint
        case .lavender: Color(red: 0.71, green: 0.66, blue: 0.91)
        case .neon:     Color(red: 0.18, green: 1.00, blue: 0.66)
        }
    }
}
