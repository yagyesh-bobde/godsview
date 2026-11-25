import AppKit
import SwiftUI

/// Colors and metrics for reading code, shared by the virtualized diff and the file viewer.
///
/// The goal is long-session comfort: a soft charcoal page instead of pure black (less glare
/// around bright glyphs), 13-point SF Mono in the fixed 24-point rows, line numbers that
/// recede on unchanged lines, and low-chroma change fills with a crisp edge bar so additions
/// and deletions stay obvious without large saturated blocks.
enum CodeTheme {
    static var font: NSFont { .monospacedSystemFont(ofSize: 13, weight: .regular) }
    /// Width of one monospaced column.
    static let advance: CGFloat = ("0" as NSString).size(withAttributes: [.font: font]).width

    static let background = NSColor(white: 0.065, alpha: 1)
    static let text = NSColor(white: 0.86, alpha: 1)

    /// Line numbers: quiet on unchanged lines, readable (≥ 4.5:1) on changed ones.
    static let gutterText = NSColor(white: 0.43, alpha: 1)
    static let changedGutterText = NSColor(white: 0.78, alpha: 1)
    static let gutterFill = NSColor(white: 0.085, alpha: 1)

    static let additionFill = NSColor(srgbRed: 0.105, green: 0.195, blue: 0.145, alpha: 1)
    static let additionGutter = NSColor(srgbRed: 0.13, green: 0.245, blue: 0.175, alpha: 1)
    static let additionEdge = NSColor(Ink.green)
    static let deletionFill = NSColor(srgbRed: 0.225, green: 0.105, blue: 0.12, alpha: 1)
    static let deletionGutter = NSColor(srgbRed: 0.28, green: 0.125, blue: 0.14, alpha: 1)
    static let deletionEdge = NSColor(Ink.red)
    static let hunkFill = NSColor(srgbRed: 0.08, green: 0.10, blue: 0.135, alpha: 1)
    static let hunkText = NSColor(srgbRed: 0.56, green: 0.71, blue: 0.96, alpha: 1)

    /// Left padding before the first gutter digit.
    static let inset: CGFloat = 12
    /// "  old new  " occupies this many columns before the +/− marker.
    static let gutterColumns = 13
    static var gutterWidth: CGFloat { inset + CGFloat(gutterColumns) * advance - advance * 0.5 }

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
