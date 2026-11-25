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
    static let gutterText = NSColor(white: 0.42, alpha: 1)
    static let changedGutterText = NSColor(white: 0.86, alpha: 1)
    /// T3: code surface mixed with 3% foreground.
    static let gutterFill = NSColor(srgbRed: 0.088, green: 0.088, blue: 0.088, alpha: 1)

    /// Code surface 70% + emerald-500 30%, and 60/40 for the number cell.
    static let additionFill = NSColor(srgbRed: 0.062, green: 0.261, blue: 0.195, alpha: 1)
    static let additionGutter = NSColor(srgbRed: 0.062, green: 0.327, blue: 0.240, alpha: 1)
    /// emerald-400, T3's addition foreground.
    static let additionEdge = NSColor(srgbRed: 0.204, green: 0.827, blue: 0.600, alpha: 1)
    /// Code surface 70% + T3's error red (red-500 with 10% white) 30%, and 60/40.
    static let deletionFill = NSColor(srgbRed: 0.326, green: 0.145, blue: 0.145, alpha: 1)
    static let deletionGutter = NSColor(srgbRed: 0.414, green: 0.173, blue: 0.173, alpha: 1)
    /// red-400, T3's deletion foreground.
    static let deletionEdge = NSColor(srgbRed: 0.973, green: 0.443, blue: 0.443, alpha: 1)
    /// Hunk separators sit one quiet step off the code surface (5% foreground) with
    /// half-strength text, like T3's separators.
    static let hunkFill = NSColor(srgbRed: 0.105, green: 0.105, blue: 0.108, alpha: 1)
    static let hunkText = NSColor(white: 0.52, alpha: 1)

    /// Width of the change bar on the left edge.
    static let edge: CGFloat = 3
    /// Left padding before the line number.
    static let inset: CGFloat = 10
    /// Digits reserved for the single line-number column; longer numbers push the code by a column.
    static let numberColumns = 4
    /// The number column plus a two-column gap before the code.
    static let gutterColumns = numberColumns + 2
    static var gutterWidth: CGFloat { inset + (CGFloat(numberColumns) + 1) * advance }

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
