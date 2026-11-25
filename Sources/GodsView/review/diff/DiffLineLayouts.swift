import CoreText
import Foundation

/// One coordinator owns one snapshot's layouts. NSCache supports concurrent reads
/// and writes; each immutable Core Text line can be drawn as soon as it is published.
final class DiffLineLayouts: @unchecked Sendable {
    private let lines = NSCache<NSNumber, CTLine>()

    init() {
        lines.totalCostLimit = 12 << 20
        lines.countLimit = 4096
    }

    func layout(file: Int, line: Int, snapshot: ReviewSnapshot) -> CTLine {
        let key = NSNumber(value: (UInt64(file) << 32) | UInt64(line))
        if let cached = lines.object(forKey: key) { return cached }
        let value = snapshot.lines[file][line].attributed(path: snapshot.files[file].filename)
        let shaped = CTLineCreateWithAttributedString(value)
        lines.setObject(shaped, forKey: key, cost: value.length * 24 + 192)
        return shaped
    }
}
