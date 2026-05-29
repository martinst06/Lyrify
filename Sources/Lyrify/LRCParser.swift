import Foundation

struct LRCLine: Identifiable {
    let id: Int
    let time: Double
    let text: String
}

struct LRCParser {
    private static let pattern = try! NSRegularExpression(
        pattern: #"\[(\d+):(\d+(?:\.\d+)?)\](.*)"#
    )

    static func parse(_ lrc: String) -> [LRCLine] {
        var lines: [(Double, String)] = []

        for raw in lrc.components(separatedBy: "\n") {
            let range = NSRange(raw.startIndex..., in: raw)
            guard let m = pattern.firstMatch(in: raw, range: range),
                  let r1 = Range(m.range(at: 1), in: raw),
                  let r2 = Range(m.range(at: 2), in: raw),
                  let r3 = Range(m.range(at: 3), in: raw) else { continue }

            let minutes = Double(raw[r1]) ?? 0
            let seconds = Double(raw[r2]) ?? 0
            let text    = raw[r3].trimmingCharacters(in: .whitespaces)
            lines.append((minutes * 60 + seconds, text))
        }

        lines.sort { $0.0 < $1.0 }
        return lines.enumerated().map { LRCLine(id: $0, time: $1.0, text: $1.1) }
    }
}
