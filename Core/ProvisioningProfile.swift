import Foundation

public struct ProfileCertificate: Sendable {
    public var data: Data
    public var expires: Date?
}
public struct ProvisioningProfile: Sendable {
    public var name: String
    public var uuid: String
    public var expires: Date
    public var certificates: [ProfileCertificate]
    public var signingCertificateIndex: Int? = nil
    public var activeCertificates: [ProfileCertificate] {
        if let i = signingCertificateIndex, certificates.indices.contains(i) { return [certificates[i]] }
        return certificates
    }
    /// Conservative deadline when multiple permitted signing certificates are embedded.
    public var deadline: Date { ([expires] + activeCertificates.compactMap(\.expires)).min()! }
    public static func decode(_ cms: Data) throws -> Self {
        guard cms.count <= 16 * 1024 * 1024 else { throw ProfileError.invalid }
        let plist: Data
        if cms.starts(with: Data("<?xml".utf8)) || cms.starts(with: Data("bplist00".utf8)) { plist = cms }
        else {
            // CMS SignedData -> encapContentInfo -> [0] EXPLICIT OCTET STRING.
            // Parse the ASN.1 envelope; don't search arbitrary certificate bytes for XML.
            let root = try DERNode.read(cms, at: 0)
            let outer = try root.children(cms)
            guard root.tag == 0x30, outer.count == 2, outer[0].tag == 6, outer[1].tag == 0xa0 else { throw ProfileError.invalid }
            let wrapper = try outer[1].children(cms)
            guard wrapper.count == 1, wrapper[0].tag == 0x30 else { throw ProfileError.invalid }
            let signed = try wrapper[0].children(cms)
            guard signed.count >= 3, signed[2].tag == 0x30 else { throw ProfileError.invalid }
            let content = try signed[2].children(cms)
            guard content.count == 2, content[1].tag == 0xa0 else { throw ProfileError.invalid }
            let octets = try content[1].children(cms)
            guard octets.count == 1, octets[0].tag == 4 else { throw ProfileError.invalid }
            plist = cms.subdata(in: octets[0].body)
        }
        guard let values = try PropertyListSerialization.propertyList(from: plist, options: [], format: nil) as? [String: Any],
              let expires = values["ExpirationDate"] as? Date else { throw ProfileError.invalid }
        let certificates = (values["DeveloperCertificates"] as? [Data] ?? []).map { ProfileCertificate(data: $0, expires: certificateExpiration($0)) }
        return Self(name: values["Name"] as? String ?? "未命名描述文件", uuid: values["UUID"] as? String ?? "unknown", expires: expires, certificates: certificates)
    }
    /// Match a permitted certificate against the executable's CMS signature, rather than
    /// assuming DeveloperCertificates[0] is the certificate actually used for signing.
    public mutating func identifySigner(in executable: Data) {
        func u32(_ offset: Int, big: Bool = false) -> Int? {
            guard offset >= 0, offset + 4 <= executable.count else { return nil }
            let bytes = executable[offset..<(offset + 4)]
            return (big ? Array(bytes) : Array(bytes.reversed())).reduce(0) { ($0 << 8) | Int($1) }
        }
        guard u32(0) == 0xfeedfacf, let count = u32(16), count <= 4096 else { return }
        var cursor = 32
        for _ in 0..<count {
            guard let command = u32(cursor), let size = u32(cursor + 4), size >= 8, size <= executable.count - cursor else { return }
            if command == 0x1d {
                guard size >= 16, let offset = u32(cursor + 8), let length = u32(cursor + 12), length >= 12,
                      offset <= executable.count - length, u32(offset, big: true) == 0xfade0cc0,
                      let total = u32(offset + 4, big: true), total >= 12, total <= length, let blobs = u32(offset + 8, big: true), blobs <= (total - 12) / 8 else { return }
                for i in 0..<blobs {
                    guard let slot = u32(offset + 12 + i * 8, big: true), let relative = u32(offset + 16 + i * 8, big: true) else { return }
                    if slot != 0x10000 { continue }
                    guard relative <= total - 8, u32(offset + relative, big: true) == 0xfade0b01,
                          let cmsLength = u32(offset + relative + 4, big: true), cmsLength >= 8, cmsLength <= total - relative else { return }
                    let cms = executable.subdata(in: (offset + relative + 8)..<(offset + relative + cmsLength))
                    let matches = certificates.indices.filter { !certificates[$0].data.isEmpty && cms.range(of: certificates[$0].data) != nil }
                    if matches.count == 1 { signingCertificateIndex = matches[0] }
                    return
                }
                return
            }
            cursor += size
        }
    }
    public static func certificateExpiration(_ data: Data) -> Date? {
        do {
            let cert = try DERNode.read(data, at: 0).children(data)
            guard let tbs = cert.first, tbs.tag == 0x30 else { return nil }
            let fields = try tbs.children(data)
            let offset = fields.first?.tag == 0xa0 ? 1 : 0
            guard fields.count > offset + 3, fields[offset + 3].tag == 0x30 else { return nil }
            let validity = try fields[offset + 3].children(data)
            guard validity.count == 2 else { return nil }
            return DERNode.date(data, validity[1])
        } catch { return nil }
    }
}
public enum ProfileError: Error { case invalid }
private struct DERNode {
    var tag: UInt8
    var body: Range<Int>
    var end: Int { body.upperBound }
    static func read(_ data: Data, at start: Int) throws -> Self {
        guard start >= 0, start + 2 <= data.count else { throw ProfileError.invalid }
        let tag = data[start]; var cursor = start + 2; let first = Int(data[start + 1]); var length = first
        if first >= 128 {
            let bytes = first & 127
            guard bytes > 0, bytes <= 4, cursor + bytes <= data.count else { throw ProfileError.invalid }
            length = 0
            for _ in 0..<bytes { length = (length << 8) | Int(data[cursor]); cursor += 1 }
        }
        guard length <= data.count - cursor else { throw ProfileError.invalid }
        return Self(tag: tag, body: cursor..<(cursor + length))
    }
    func children(_ data: Data) throws -> [Self] {
        var cursor = body.lowerBound; var result: [Self] = []
        while cursor < end {
            let node = try Self.read(data, at: cursor)
            guard node.end <= end else { throw ProfileError.invalid }
            result.append(node); cursor = node.end
        }
        return result
    }
    static func date(_ data: Data, _ node: Self) -> Date? {
        guard node.tag == 0x17 || node.tag == 0x18, var text = String(data: data.subdata(in: node.body), encoding: .ascii) else { return nil }
        if node.tag == 0x17 {
            guard text.count == 13, let year = Int(text.prefix(2)) else { return nil }
            text = (year >= 50 ? "19" : "20") + text
        }
        guard text.count == 15, text.hasSuffix("Z") else { return nil }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMddHHmmss'Z'"; formatter.isLenient = false
        return formatter.date(from: text)
    }
}

public enum CertificateReminderPlan {
    /// One local alert per date, including the expiration date, at 09:00 (or shortly after enabling).
    public static func dates(deadline: Date, days: Int, now: Date, calendar: Calendar = .current) -> [Date] {
        guard [3, 7, 15, 30].contains(days), deadline > now,
              let start = calendar.date(byAdding: .day, value: -days, to: calendar.startOfDay(for: deadline)) else { return [] }
        var day = max(calendar.startOfDay(for: now), start); let last = calendar.startOfDay(for: deadline)
        var result: [Date] = []
        while day <= last && result.count < 32 {
            let morning = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day) ?? day
            let fire = max(morning, now.addingTimeInterval(3))
            if fire <= deadline { result.append(fire) }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day), next > day else { break }; day = next
        }
        return result
    }
}
