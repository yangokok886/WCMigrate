import Foundation
public enum DiagnosticPages {
    public static func split(_ text: String, limit: Int = 6000) -> [String] {
        precondition(limit > 0)
        guard !text.isEmpty else { return ["暂无诊断内容"] }
        var result: [String] = []; var start = text.startIndex
        while start < text.endIndex {
            let end = text.index(start, offsetBy: limit, limitedBy: text.endIndex) ?? text.endIndex
            result.append(String(text[start..<end])); start = end
        }
        return result
    }
}
