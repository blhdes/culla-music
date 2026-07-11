import Foundation

/// Converts the lightweight HTML Apple Music embeds in editorial notes into
/// an `AttributedString` that SwiftUI's `Text` renders with real formatting.
///
/// Catalog `EditorialNotes` arrive as strings like
/// `"<b>100 Best Albums</b> … the way Michael Jackson's <i>Thriller</i> did"`
/// — rendering them raw shows the tags as literal text (the bug this fixes).
/// The Wikipedia "About" never hits this because its REST endpoint returns
/// plain text.
///
/// Deliberately NOT the `NSAttributedString` HTML importer: that one is
/// WebKit-backed, main-thread-only, slow on first use, and stamps its own
/// fonts over the app's typography. Apple's editorial notes only ever use a
/// tiny tag set, so a hand-rolled scan handles all of it and stays cheap and
/// thread-safe:
/// - `<b>` / `<strong>` → bold, `<i>` / `<em>` → italic (nesting supported)
/// - `<br>` → line break, `</p>` → paragraph break
/// - any other tag (e.g. `<a href=…>`) is stripped, keeping its inner text
/// - character entities (`&amp;`, `&#8217;`, `&#x2019;`, …) are decoded
enum EditorialHTML {
    /// Parses `html` into rich text. Returns nil when nothing readable
    /// survives (e.g. a note that is only markup), so callers can hide the
    /// section exactly like they would for an absent note.
    static func attributedString(from html: String) -> AttributedString? {
        var result = AttributedString()
        var pendingText = ""
        var boldDepth = 0
        var italicDepth = 0

        // Moves the accumulated plain text into `result`, stamped with the
        // formatting state that was active while it was collected. Called
        // before any state change (tag open/close) so each run keeps the
        // traits it was read under.
        func flush() {
            guard !pendingText.isEmpty else { return }
            var run = AttributedString(decodeEntities(pendingText))
            var intent: InlinePresentationIntent = []
            if boldDepth > 0 { intent.insert(.stronglyEmphasized) }
            if italicDepth > 0 { intent.insert(.emphasized) }
            if !intent.isEmpty { run.inlinePresentationIntent = intent }
            result += run
            pendingText = ""
        }

        var index = html.startIndex
        while index < html.endIndex {
            let character = html[index]
            // A "<" with a matching ">" is a tag; a stray "<" (no closer
            // anywhere ahead) falls through and stays literal text.
            if character == "<", let close = html[index...].firstIndex(of: ">") {
                let rawTag = html[html.index(after: index)..<close]
                let tag = rawTag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let isClosing = tag.hasPrefix("/")
                // First token, minus the closing slash and any attributes —
                // "/p", `a href="…"`, "br/" all reduce to their bare name.
                let name = tag
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    .split(whereSeparator: { $0 == " " || $0 == "\n" })
                    .first.map(String.init) ?? ""

                switch name {
                case "b", "strong":
                    flush()
                    boldDepth = max(0, boldDepth + (isClosing ? -1 : 1))
                case "i", "em":
                    flush()
                    italicDepth = max(0, italicDepth + (isClosing ? -1 : 1))
                case "br":
                    flush()
                    result += AttributedString("\n")
                case "p" where isClosing:
                    flush()
                    result += AttributedString("\n\n")
                default:
                    // Unknown / unstyled tag (opening <p>, <a>, spans…):
                    // drop the tag itself, keep whatever text it wraps.
                    break
                }
                index = html.index(after: close)
            } else {
                pendingText.append(character)
                index = html.index(after: index)
            }
        }
        flush()

        // A trailing </p> or <br> leaves dangling newlines — trim them so the
        // note ends where its text ends.
        while let last = result.characters.last, last.isWhitespace {
            result.characters.removeLast()
        }
        return result.characters.isEmpty ? nil : result
    }

    /// Decodes the character entities that actually show up in editorial
    /// notes: the five XML named ones, `&nbsp;`, and numeric forms (decimal
    /// `&#8217;` and hex `&#x2019;`). Unknown entities are left as-is rather
    /// than eaten, so imperfect input degrades to visible text, never loss.
    private static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var output = ""
        output.reserveCapacity(text.count)
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "&",
               let semicolon = text[index...].firstIndex(of: ";"),
               // Entities are short; a far-away ";" means this "&" is literal.
               text.distance(from: index, to: semicolon) <= 10 {
                let entity = String(text[text.index(after: index)..<semicolon])
                if let decoded = decode(entity) {
                    output.append(decoded)
                    index = text.index(after: semicolon)
                    continue
                }
            }
            output.append(character)
            index = text.index(after: index)
        }
        return output
    }

    private static func decode(_ entity: String) -> String? {
        switch entity.lowercased() {
        case "amp":  return "&"
        case "lt":   return "<"
        case "gt":   return ">"
        case "quot": return "\""
        case "apos": return "'"
        case "nbsp": return "\u{00A0}"
        default:
            guard entity.hasPrefix("#") else { return nil }
            let number = entity.dropFirst()
            let value: UInt32? = number.hasPrefix("x") || number.hasPrefix("X")
                ? UInt32(number.dropFirst(), radix: 16)
                : UInt32(number)
            guard let value, let scalar = Unicode.Scalar(value) else { return nil }
            return String(Character(scalar))
        }
    }
}
