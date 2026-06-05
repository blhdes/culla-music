import Foundation

/// Developer-only switches for previewing alternate UI states on a device that
/// can't otherwise reach them. Not user-facing.
enum DebugFlags {

    /// Forces the pre-iOS-26 fallback UI (no Liquid Glass) to render on *any*
    /// device, so the iOS 17–25 path can be reviewed on an iOS 26 phone.
    ///
    /// To preview: flip `previewLegacyUI` to `true`, build to device, look
    /// around, then flip it back. Wrapped in `#if DEBUG` so a forgotten `true`
    /// can never reach a Release / App Store build — there it's always `false`
    /// and the real `#available` check decides.
    static var forceLegacyUI: Bool {
        #if DEBUG
        return previewLegacyUI
        #else
        return false
        #endif
    }

    /// ⬇︎ Flip this to `true` to preview the legacy fallback, back to `false` when done.
    private static let previewLegacyUI = false
}
