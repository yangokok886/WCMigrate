import XCTest
@testable import TransferCore
final class ProvisioningProfileTests: XCTestCase {
    func der(_ tag: UInt8, _ content: Data) -> Data {
        let n = content.count
        let length: [UInt8] = n < 128 ? [UInt8(n)] : (n < 256 ? [0x81, UInt8(n)] : [0x82, UInt8(n >> 8), UInt8(n & 255)])
        return Data([tag] + length) + content
    }
    func profile(_ expiration: Date) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: ["Name": "Test Profile", "UUID": "test-id", "ExpirationDate": expiration, "DeveloperCertificates": []], format: .xml, options: 0)
    }
    func testCMSDecodingAndMalformedEnvelope() throws {
        let expiration = Date(timeIntervalSince1970: 1_900_000_000)
        let xml = try profile(expiration)
        let content = der(0x30, der(6, Data([0x2a, 3])) + der(0xa0, der(4, xml)))
        let signed = der(0x30, der(2, Data([1])) + der(0x31, Data()) + content)
        let cms = der(0x30, der(6, Data([0x2a, 3])) + der(0xa0, signed))
        let p = try ProvisioningProfile.decode(cms)
        XCTAssertEqual(p.name, "Test Profile"); XCTAssertEqual(p.deadline, expiration)
        XCTAssertThrowsError(try ProvisioningProfile.decode(cms.dropLast()))
        XCTAssertThrowsError(try ProvisioningProfile.decode(Data([0x30, 0x80, 0, 0])))
        XCTAssertThrowsError(try ProvisioningProfile.decode(Data("fake " .utf8) + xml))
    }
    func testCertificateValidityUTCAndGeneralizedTime() throws {
        for (tag, end) in [(UInt8(0x17), "491231235959Z"), (UInt8(0x18), "20491231235959Z")] {
            let validity = der(0x30, der(0x17, Data("260101000000Z".utf8)) + der(tag, Data(end.utf8)))
            let tbs = der(0x30, der(0xa0, der(2, Data([2]))) + der(2, Data([1])) + der(0x30, Data()) + der(0x30, Data()) + validity)
            let cert = der(0x30, tbs)
            let date = try XCTUnwrap(ProvisioningProfile.certificateExpiration(cert))
            var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(secondsFromGMT: 0)!
            XCTAssertEqual(cal.component(.year, from: date), 2049)
        }
        XCTAssertNil(ProvisioningProfile.certificateExpiration(Data([1, 2, 3])))
    }
    func testRealOpenSSLCMSAndCertificateAndMachOSignerMatch() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func run(_ args: [String]) throws -> Data {
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl"); process.arguments = args
            process.currentDirectoryURL = directory; let pipe = Pipe(); process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
            try process.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw ProfileError.invalid }; return data
        }
        _ = try run(["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", "test.key", "-out", "test.crt", "-days", "30", "-subj", "/CN=WCMigrate Test Fixture"])
        let cert = try run(["x509", "-in", "test.crt", "-outform", "DER"])
        let certificateExpiry = try XCTUnwrap(ProvisioningProfile.certificateExpiration(cert))
        let expiration = Date().addingTimeInterval(60 * 86400)
        let values: [String: Any] = ["Name": "Real CMS Fixture", "UUID": "real-cms-test", "ExpirationDate": expiration, "DeveloperCertificates": [Data([1, 2, 3]), cert]]
        try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0).write(to: directory.appendingPathComponent("profile.plist"))
        _ = try run(["cms", "-sign", "-binary", "-nodetach", "-in", "profile.plist", "-signer", "test.crt", "-inkey", "test.key", "-outform", "DER", "-out", "profile.mobileprovision"])
        let cms = try Data(contentsOf: directory.appendingPathComponent("profile.mobileprovision"))
        var parsed = try ProvisioningProfile.decode(cms)
        XCTAssertEqual(parsed.deadline, certificateExpiry)
        XCTAssertEqual(parsed.name, "Real CMS Fixture")
        func word(_ value: Int, big: Bool = false) -> Data {
            let bytes = [UInt8(value & 255), UInt8((value >> 8) & 255), UInt8((value >> 16) & 255), UInt8((value >> 24) & 255)]
            return Data(big ? bytes.reversed() : bytes)
        }
        let blob = word(0xfade0b01, big: true) + word(cms.count + 8, big: true) + cms
        let superblob = word(0xfade0cc0, big: true) + word(blob.count + 20, big: true) + word(1, big: true) + word(0x10000, big: true) + word(20, big: true) + blob
        var macho = word(0xfeedfacf) + Data(repeating: 0, count: 12) + word(1) + word(16) + Data(repeating: 0, count: 8)
        macho += word(0x1d) + word(16) + word(48) + word(superblob.count) + superblob
        parsed.identifySigner(in: macho)
        XCTAssertEqual(parsed.signingCertificateIndex, 1)
        XCTAssertEqual(parsed.activeCertificates.count, 1)
        XCTAssertEqual(parsed.activeCertificates.first?.data, cert)
    }
    func testDailySchedulingAllWindowsAndExpiredProfile() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let deadline = cal.date(from: DateComponents(year: 2026, month: 12, day: 15, hour: 18))!
        let now = cal.date(byAdding: .day, value: -40, to: deadline)!
        for days in [3, 7, 15, 30] {
            let dates = CertificateReminderPlan.dates(deadline: deadline, days: days, now: now, calendar: cal)
            XCTAssertEqual(dates.count, days + 1)
            XCTAssertEqual(Set(dates.map { cal.startOfDay(for: $0) }).count, dates.count)
            XCTAssertTrue(dates.allSatisfy { $0 < deadline && cal.component(.hour, from: $0) == 9 })
        }
        XCTAssertTrue(CertificateReminderPlan.dates(deadline: deadline, days: 7, now: deadline, calendar: cal).isEmpty)
        let late = cal.date(byAdding: .hour, value: -2, to: deadline)!
        let today = CertificateReminderPlan.dates(deadline: deadline, days: 3, now: late, calendar: cal)
        XCTAssertEqual(today.count, 1); XCTAssertEqual(today.first!, late.addingTimeInterval(3))
    }
}
