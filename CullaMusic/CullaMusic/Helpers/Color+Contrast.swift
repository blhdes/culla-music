import SwiftUI
import UIKit

extension Color {
    /// Foreground (softened black or white) to lay on top of this color used as
    /// an **opaque** fill — the selected ModeTile, the Start CTA. White on the
    /// dark swatches (Indigo, Crimson, Emerald…), near-black on the light ones
    /// (Amber, Rose, and the bright Chartreuse/Lime/Tangerine/Aqua end).
    ///
    /// The 0.30 crossover is biased toward white on purpose: on a solid
    /// saturated fill the bold white-on-color look reads well, and only the
    /// genuinely light swatches flip to black.
    var idealForeground: Color {
        UIColor(self).wcagLuminance > 0.30 ? Color.black.opacity(0.88) : .white
    }

    /// Pure black or white for a label on this color used as a **translucent**
    /// tint — the playlist chips' glass capsules. The glass lets the light
    /// background through, so the rendered chip is lighter than the raw accent;
    /// a lower crossover (≈0.179, the point where black and white land at equal
    /// WCAG contrast) leans on black a touch more than `idealForeground` to
    /// compensate. Same luminance math, different threshold — see `wcagLuminance`.
    var contrastingLabel: Color {
        UIColor(self).wcagLuminance > 0.179 ? .black : .white
    }
}

extension UIColor {
    /// WCAG relative luminance (0…1) — the perceptual lightness both contrast
    /// helpers above use to choose black-vs-white text. Linearizes each sRGB
    /// channel (undoing gamma) then weights them by the human eye's sensitivity
    /// (green ≫ red ≫ blue). Falls back to 0 — treats the color as dark, so the
    /// caller defaults to white text — if the components can't be read.
    var wcagLuminance: CGFloat {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard getRed(&r, green: &g, blue: &b, alpha: &a) else { return 0 }
        func linear(_ c: CGFloat) -> CGFloat {
            c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }
}
