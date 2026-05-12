import SwiftUI

private struct AppAccentKey: EnvironmentKey {
    static let defaultValue: Color = .primary
}

private struct AppAccentSecondaryKey: EnvironmentKey {
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
}
