import SwiftUI
import UIKit

extension Color {
    /// The most legible foreground (near-black or white) to lay *on top of*
    /// this color when it's used as a solid fill. Picks by perceptual
    /// luminance so it adapts to any accent palette — white on the dark
    /// swatches (Indigo, Crimson, Emerald…), near-black on the light ones
    /// (Amber, Rose). Hardcoding white would leave the light swatches just as
    /// unreadable as black-on-dark was.
    var idealForeground: Color {
        UIColor(self).isLightForContrast ? Color.black.opacity(0.88) : .white
    }
}

private extension UIColor {
    /// Rec. 601 luma — cheap, perceptually weighted, good enough for a binary
    /// light/dark decision. The 0.6 threshold puts Amber/Rose on the dark-text
    /// side and every other palette swatch on white text. Falls back to white
    /// (treats the color as dark) if components can't be read.
    var isLightForContrast: Bool {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard getRed(&r, green: &g, blue: &b, alpha: &a) else { return false }
        return (0.299 * r + 0.587 * g + 0.114 * b) > 0.6
    }
}
