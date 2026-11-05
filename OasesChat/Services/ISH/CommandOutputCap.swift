import Foundation

/// A command's captured output keeps its first and last 512 KB; the middle of a longer one
/// (`yes`, `cat` of a model file) is replaced by a marker so it cannot exhaust memory. Mirrors
/// the cap `ISHShellExecutor` applies to its own buffers. Sizes are UTF-8 bytes (`utf8.count`
/// is O(1) on native strings); cuts fall on Unicode scalar boundaries.
enum CommandOutputCap {
    static let keepBytes = 512 * 1024
    static let marker = "\n[… Oases: the middle of this very long output was dropped …]\n"

    static func append(_ text: String, to buffer: inout String) {
        buffer += text
        // Trim in batches (64 KB over the limit), not on every line.
        guard buffer.utf8.count > keepBytes * 2 + marker.utf8.count + 64 * 1024 else { return }
        trim(&buffer)
    }

    static func trim(_ buffer: inout String) {
        let utf8 = buffer.utf8
        guard utf8.count > keepBytes * 2 + marker.utf8.count else { return }
        var headEnd = utf8.index(utf8.startIndex, offsetBy: keepBytes)
        if let existing = buffer.range(of: marker),
           utf8.distance(from: utf8.startIndex, to: existing.lowerBound) <= keepBytes {
            headEnd = existing.lowerBound
        }
        let tailStart = utf8.index(utf8.endIndex, offsetBy: -keepBytes)
        buffer = String(buffer[..<headEnd]) + marker + String(buffer[tailStart...])
    }
}
