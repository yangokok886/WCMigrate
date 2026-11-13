import Foundation
import CommonCrypto

/// Reads the account identity from WeChat's LoginInfo2.dat.
///
/// Reads the length-prefixed account records inside LoginInfo2.dat. Only the
/// explicit wxid and alias fields are used; nicknames and opaque bytes are ignored.
public enum WeChatIdentityResolver {
    private static let md5Regex = try! NSRegularExpression(pattern: #"^[a-f0-9]{32}$"#)
    private static let loginFileName = "LoginInfo2.dat"

    private struct Result {
        var account: String?
        var wxid: String?
        var fileFound = false
        var unreadable = false
    }

    /// Returns one display value: the WeChat ID first, otherwise wxid.
    public static func preferredIdentifier(in root: URL) -> String? {
        let results = candidateDirectories(in: root).map(inspect)
        return results.compactMap(\.account).first ?? results.compactMap(\.wxid).first
    }

    /// Produces a short diagnostic for the run log without exposing message data.
    public static func diagnostic(in root: URL) -> (identifier: String?, detail: String) {
        let candidates = candidateDirectories(in: root)
        var foundFiles = 0
        var unreadableFiles = 0
        var firstAccount: String?
        var firstWxid: String?
        for directory in candidates {
            let result = inspect(directory)
            if result.fileFound { foundFiles += 1 }
            if result.unreadable { unreadableFiles += 1 }
            firstAccount = firstAccount ?? result.account
            firstWxid = firstWxid ?? result.wxid
        }

        let identifier = firstAccount ?? firstWxid
        if let identifier {
            var detail = "已识别身份=\(identifier) · LoginInfo2.dat=\(foundFiles)"
            if let firstWxid, firstWxid != identifier { detail += " · 微信号字段=13 · wxid=\(firstWxid)" }
            else { detail += " · 微信号字段为空或无效，显示wxid" }
            return (identifier, detail)
        }

        let unreadable = unreadableFiles > 0 ? " · 无法读取=\(unreadableFiles)" : ""
        return (nil, "未识别到微信号或 wxid · 非全零MD5目录=\(candidates.count) · Documents/LoginInfo2.dat=\(foundFiles)\(unreadable)")
    }

    private static func candidateDirectories(in root: URL) -> [URL] {
        let fm = FileManager.default
        // Callers may pass Documents itself or one concrete MD5 directory.
        // Never append Documents below an already-selected account directory.
        if isMD5(root.lastPathComponent) && !isAllZero(root.lastPathComponent) {
            return [root]
        }
        let documents = root.lastPathComponent == "Documents" ? root : root.appendingPathComponent("Documents")
        guard let entries = try? fm.contentsOfDirectory(at: documents, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return isMD5(root.lastPathComponent) && !isAllZero(root.lastPathComponent) ? [root] : []
        }

        return entries.filter { url in
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return false }
            let name = url.lastPathComponent
            return isMD5(name) && !isAllZero(name)
        }
    }

    private static func inspect(_ directory: URL) -> Result {
        let url = directory.deletingLastPathComponent().appendingPathComponent(loginFileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return Result() }
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
            var result = Result()
            result.fileFound = true
            result.unreadable = true
            return result
        }
        var result = parse(data, matchingDirectoryMD5: directory.lastPathComponent.lowercased())
        result.fileFound = true
        return result
    }

    private static func parse(_ data: Data, matchingDirectoryMD5 expectedMD5: String) -> Result {
        // Field 1 of the outer message contains a sequence of varint-length
        // prefixed protobuf account records (not readable-text fragments).
        guard let envelope = fields(in: Array(data)), let packed = envelope[1] else { return Result() }
        var cursor = 0
        var result = Result()
        while cursor < packed.count {
            guard let length = varint(packed, cursor: &cursor), length <= UInt64(packed.count - cursor) else {
                return result
            }
            let end = cursor + Int(length)
            let record = Array(packed[cursor..<end])
            cursor = end
            guard let values = fields(in: record),
                  let identity = values[1], let wxid = String(bytes: identity, encoding: .utf8),
                  wxid.range(of: #"^wxid_[A-Za-z0-9_]+$"#, options: .regularExpression) != nil,
                  md5Hex(wxid) == expectedMD5 else { continue }
            // Field 11 repeats the wxid in both supplied samples. Reject a
            // conflicting record rather than associating an alias with the wrong account.
            if let repeated = values[11], repeated != identity { continue }
            result.wxid = wxid
            // Field 3 is nickname, field 8 is opaque data. Neither is an alias.
            if let bytes = values[13], let alias = String(bytes: bytes, encoding: .utf8),
               alias.range(of: #"^[A-Za-z][A-Za-z0-9_-]{5,19}$"#, options: .regularExpression) != nil,
               !alias.hasPrefix("wxid_") {
                result.account = alias
                return result
            }
        }
        return result
    }

    /// Bounded protobuf wire reader. Never interprets unknown field payloads as text.
    private static func fields(in bytes: [UInt8]) -> [UInt64: [UInt8]]? {
        var cursor = 0
        var result: [UInt64: [UInt8]] = [:]
        while cursor < bytes.count {
            guard let key = varint(bytes, cursor: &cursor), key >> 3 > 0 else { return nil }
            switch key & 7 {
            case 0:
                guard varint(bytes, cursor: &cursor) != nil else { return nil }
            case 1:
                guard bytes.count - cursor >= 8 else { return nil }
                cursor += 8
            case 2:
                guard let length = varint(bytes, cursor: &cursor), length <= UInt64(bytes.count - cursor) else { return nil }
                let end = cursor + Int(length)
                // These are singular fields. Ambiguous duplicate values fail closed.
                let value = Array(bytes[cursor..<end])
                if let existing = result[key >> 3], existing != value { return nil }
                result[key >> 3] = value
                cursor = end
            case 5:
                guard bytes.count - cursor >= 4 else { return nil }
                cursor += 4
            default:
                return nil
            }
        }
        return result
    }

    private static func varint(_ bytes: [UInt8], cursor: inout Int) -> UInt64? {
        var value: UInt64 = 0
        for shift in stride(from: 0, through: 63, by: 7) {
            guard cursor < bytes.count else { return nil }
            let byte = bytes[cursor]
            cursor += 1
            if shift == 63 && byte > 1 { return nil }
            value |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 { return value }
        }
        return nil
    }

    private static func md5Hex(_ value: String) -> String {
        var digest = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
        let bytes = Array(value.utf8)
        bytes.withUnsafeBytes { rawBuffer in
            _ = CC_MD5(rawBuffer.baseAddress, CC_LONG(bytes.count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func isMD5(_ value: String) -> Bool {
        md5Regex.firstMatch(in: value, range: NSRange(value.startIndex..<value.endIndex, in: value)) != nil
    }

    private static func isAllZero(_ value: String) -> Bool {
        value.allSatisfy { $0 == "0" }
    }
}
