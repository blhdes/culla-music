import SwiftUI

extension Color {

    /// Canonical neon palette — these hex strings are stored in SwiftData and used as identity keys.
    static let neonHexes: [String] = [
        "#FF2D78", "#00B4FF", "#39FF14", "#BF00FF",
        "#FFE600", "#FF6600", "#00FFEE", "#FF0040",
        "#CCFF00", "#FF00FF",
        "#FF4500", "#FFAA00", "#80FF00", "#00FF80",
        "#00AAFF", "#5500FF", "#DD00FF", "#FF00AA",
    ]

    private static let neonHexesDark: [String] = [
        "#FF2D78", "#00B4FF", "#30E612", "#BF00FF",
        "#FFCC00", "#FF6600", "#00E6D6", "#FF0040",
        "#B8E600", "#FF00FF",
        "#FF4500", "#FFAA00", "#72E600", "#00E673",
        "#00A3F5", "#5500FF", "#DD00FF", "#FF00AA",
    ]

    private static let neonHexesLight: [String] = [
        "#D42560", "#0088CC", "#1DAF00", "#9500CC",
        "#B88700", "#D45500", "#008877", "#CC0033",
        "#6E9E00", "#CC00CC",
        "#CC3600", "#CC8500", "#4E9900", "#009950",
        "#0077CC", "#3D00CC", "#AA00CC", "#CC0080",
    ]

    /// Returns a Color that adapts between light and dark mode automatically.
    static func adaptiveNeon(hex: String) -> Color {
        let darkHex: String
        let lightHex: String
        if let index = neonHexes.firstIndex(of: hex) {
            darkHex = neonHexesDark[index]
            lightHex = neonHexesLight[index]
        } else {
            darkHex = hex
            lightHex = hex
        }
        return Color(UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(Color(hex: darkHex))
                : UIColor(Color(hex: lightHex))
        })
    }

    static let neons: [Color] = neonHexes.map { adaptiveNeon(hex: $0) }

    static func neon(for index: Int) -> Color {
        neons[index % neons.count]
    }

    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var rgb: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&rgb)
        self.init(
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255
        )
    }
}
