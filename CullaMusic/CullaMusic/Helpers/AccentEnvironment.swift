import SwiftUI

private struct AppAccentKey: EnvironmentKey {
    static let defaultValue: Color = .primary
}

private struct AppAccentSecondaryKey: EnvironmentKey {
    static let defaultValue: Color? = nil
}

private struct AppAccentNeutralKey: EnvironmentKey {
    static let defaultValue: Color? = nil
}

extension EnvironmentValues {
    var appAccent: Color {
        get { self[AppAccentKey.self] }
        set { self[AppAccentKey.self] = newValue }
    }

    /// Optional secondary accent. When set, surfaces that paint with the
    /// accent (e.g. the sidebar drop-target glow) can build a gradient
    /// between `appAccent` and this. Nil → fall back to a flat fill.
    var appAccentSecondary: Color? {
        get { self[AppAccentSecondaryKey.self] }
        set { self[AppAccentSecondaryKey.self] = newValue }
    }

    /// Pure-grey chip tint, non-nil only when the dynamic accent came from a
    /// monochrome cover. Surfaces that want B&W artwork to read neutral (the
    /// playlist chips) prefer this over `appAccent`; nil means "use the
    /// colored accent as normal."
    var appAccentNeutral: Color? {
        get { self[AppAccentNeutralKey.self] }
        set { self[AppAccentNeutralKey.self] = newValue }
    }
}
