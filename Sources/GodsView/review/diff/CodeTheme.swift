import AppKit
import SwiftUI

/// Colors and metrics for reading code, shared by the virtualized diff and the file viewer.
///
/// Modeled on T3 Code's diff surface (its `@pierre/diffs` theme): SF Mono 13 on a near-black
/// code surface, one line-number column (new line, or old line for deletions) instead of two,
/// no +/− column — a colored edge bar marks changes — and row tints made by mixing the code
/// surface with emerald-500 / red-500 (30% for the row, 40% for the number cell).
enum CodeTheme {
    static var font: NSFont { .monospacedSystemFont(ofSize: 13, weight: .regular) }
    /// Width of one monospaced column.
    static let advance: CGFloat = ("0" as NSString).size(withAttributes: [.font: font]).width

    /// T3 dark: `--code-background` = card (neutral-950 + 3% white) over black.
    static let background = NSColor(srgbRed: 0.062, green: 0.062, blue: 0.062, alpha: 1)
    /// T3 dark: neutral-100.
    static let text = NSColor(srgbRed: 0.93, green: 0.93, blue: 0.93, alpha: 1)

    /// Line numbers recede on unchanged lines and brighten on changed ones.
    static let gutterText = NSColor(white: 0.53, alpha: 1)  // ≥ 4.5:1 on the gutter band
    static let changedGutterText = NSColor(white: 0.88, alpha: 1)
    /// T3: code surface mixed with 3% foreground.
    static let gutterFill = NSColor(srgbRed: 0.084, green: 0.084, blue: 0.086, alpha: 1)
    /// Crisp hairline separating the line-number gutter from code.
    static let gutterRule = NSColor(white: 1, alpha: 0.055)
    /// Sticky file header surface and the dark recess between file blocks.
    static let headerFill = NSColor(white: 0.098, alpha: 1)
    static let fileGapFill = NSColor(white: 0.024, alpha: 1)

    /// Balanced emerald and crimson tints over the dark code surface so syntax colors stay legible.
    static let additionFill = NSColor(srgbRed: 0.058, green: 0.228, blue: 0.172, alpha: 1)
    static let additionGutter = NSColor(srgbRed: 0.062, green: 0.285, blue: 0.212, alpha: 1)
    /// emerald-400, T3's addition foreground.
    static let additionEdge = NSColor(srgbRed: 0.204, green: 0.827, blue: 0.600, alpha: 1)
    /// Slightly deeper red so deletions balance visually with emerald additions.
    static let deletionFill = NSColor(srgbRed: 0.268, green: 0.112, blue: 0.120, alpha: 1)
    static let deletionGutter = NSColor(srgbRed: 0.338, green: 0.134, blue: 0.144, alpha: 1)
    /// red-400, T3's deletion foreground.
    static let deletionEdge = NSColor(srgbRed: 0.973, green: 0.443, blue: 0.443, alpha: 1)
    /// The − marker sits on the deletion number cell, so it uses a lighter red (≥ 4.5:1 there).
    static let deletionMarker = NSColor(srgbRed: 1.0, green: 0.76, blue: 0.76, alpha: 1)
    static let additionMarker = NSColor(srgbRed: 0.56, green: 0.95, blue: 0.78, alpha: 1)
    /// Hunk separators sit one quiet cool step off the code surface with calm accent text.
    static let hunkFill = NSColor(srgbRed: 0.074, green: 0.094, blue: 0.128, alpha: 1)
    static let hunkText = NSColor(white: 0.56, alpha: 1)
    static let hunkAccent = NSColor(srgbRed: 0.54, green: 0.70, blue: 0.95, alpha: 1)

    /// Width of the change bar on the left edge.
    static let edge: CGFloat = 3
    /// Left padding before the line number.
    static let inset: CGFloat = 10
    /// Minimum digits for the single line-number column. Each diff sizes the column from its
    /// largest line number, so code, background and hit targets stay aligned past 9,999.
    static let numberColumns = 4
    static func digits(for largest: Int) -> Int { max(numberColumns, String(max(largest, 0)).count) }
    /// The number column, a +/− marker column, and a gap before the code.
    static func gutterColumns(_ digits: Int) -> Int { digits + 3 }
    static func gutterWidth(_ digits: Int) -> CGFloat { inset + (CGFloat(digits) + 2.5) * advance }

    /// Line height for the TextKit file viewer, matched to the diff's calm rhythm.
    static let lineHeight: CGFloat = 20
    static var paragraph: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = lineHeight
        style.maximumLineHeight = lineHeight
        return style
    }
    /// Centers 13-point glyphs inside the taller line box.
    static var baselineOffset: CGFloat { ((lineHeight - (font.ascender - font.descender)) / 2).rounded() }
}
