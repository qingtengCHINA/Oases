// Adapted from Cicada (https://github.com/wquguru/cicada), Apache License 2.0.
import Foundation

/// Tidies recognised text: the stray marks recognition leaves at breaths and hesitations.
enum HeardText {
    static func clean(_ text: String) -> String {
        var s = text
        s = s.replacingOccurrences(of: #"\s*[.。]{2,}|\s*…+"#, with: "…", options: .regularExpression)
        s = s.replacingOccurrences(of: #"…(?:[\s,，]*…)+"#, with: "…", options: .regularExpression)
        s = s.replacingOccurrences(of: #"([,，])(?:\s*[,，])+"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"[,，]\s*…|…\s*[,，]"#, with: "…", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s+([,，.。…?？!！;；:：])"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        let lead: Set<Character> = [".", ",", ";", ":", "!", "?", "…", "、", "，", "。", "；", "：", "！", "？", "-", "–", "—"]
        s = String(s.drop(while: { lead.contains($0) || $0.isWhitespace }))
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
