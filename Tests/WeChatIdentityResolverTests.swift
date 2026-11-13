import XCTest
import Foundation
import CommonCrypto
@testable import TransferCore

final class WeChatIdentityResolverTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Documents"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func varint(_ number: Int) -> [UInt8] {
        var value = number
        var bytes: [UInt8] = []
        repeat {
            let byte = UInt8(value & 127)
            value >>= 7
            bytes.append(byte | (value > 0 ? 128 : 0))
        } while value > 0
        return bytes
    }

    private func field(_ number: Int, _ text: String) -> [UInt8] {
        let bytes = Array(text.utf8)
        return varint(number << 3 | 2) + varint(bytes.count) + bytes
    }

    private func record(_ wxid: String, alias: String?) -> [UInt8] {
        // Deliberately plausible nickname/opaque text before the actual alias.
        var value = field(1, wxid) + field(2, "+8610000000000")
        value += field(3, "WrongNickname") + field(8, "strdm@opaque-random-data")
        value += field(11, wxid)
        if let alias { value += field(13, alias) }
        return varint(value.count) + value
    }

    private func write(_ records: [[UInt8]]) throws {
        let packed = records.flatMap { $0 }
        try Data([10] + varint(packed.count) + packed + [16, 0])
            .write(to: root.appendingPathComponent("Documents/LoginInfo2.dat"))
    }

    private func directory(_ wxid: String) throws -> URL {
        var digest = [UInt8](repeating: 0, count: 16)
        let bytes = Array(wxid.utf8)
        bytes.withUnsafeBytes { _ = CC_MD5($0.baseAddress, CC_LONG(bytes.count), &digest) }
        let name = digest.map { String(format: "%02x", $0) }.joined()
        let url = root.appendingPathComponent("Documents/" + name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testAliasUsesField13AndMatchesFolderHash() throws {
        let a = try directory("wxid_test_account_a")
        let b = try directory("wxid_test_account_b")
        try write([record("wxid_test_account_a", alias: "test_alias_a"), record("wxid_test_account_b", alias: "test_alias_b")])
        XCTAssertEqual(WeChatIdentityResolver.preferredIdentifier(in: a), "test_alias_a")
        XCTAssertEqual(WeChatIdentityResolver.preferredIdentifier(in: b), "test_alias_b")
    }

    func testMissingOrInvalidAliasFallsBackToWxid() throws {
        let a = try directory("wxid_test_account_a")
        for alias in [nil, "", "nickname with spaces", "+8610000000000"] as [String?] {
            try write([record("wxid_test_account_a", alias: alias)])
            XCTAssertEqual(WeChatIdentityResolver.preferredIdentifier(in: a), "wxid_test_account_a")
        }
    }

    func testUnmatchedHashAndZeroAreIgnored() throws {
        let other = try directory("wxid_unmatched")
        try write([record("wxid_test_account_a", alias: "test_alias_a")])
        XCTAssertNil(WeChatIdentityResolver.preferredIdentifier(in: other))
        let zero = root.appendingPathComponent("Documents/" + String(repeating: "0", count: 32))
        try FileManager.default.createDirectory(at: zero, withIntermediateDirectories: true)
        XCTAssertNil(WeChatIdentityResolver.preferredIdentifier(in: zero))
    }

    func testTruncatedOrTextDataDoesNotGuessIdentity() throws {
        let a = try directory("wxid_test_account_a")
        try write([record("wxid_test_account_a", alias: "test_alias_a")])
        let file = root.appendingPathComponent("Documents/LoginInfo2.dat")
        let original = try Data(contentsOf: file)
        for length in 0..<original.count - 2 {
            try original.prefix(length).write(to: file)
            XCTAssertNil(WeChatIdentityResolver.preferredIdentifier(in: a))
        }
        try Data("wxid_test_account_a WrongNickname test_alias_a".utf8).write(to: file)
        XCTAssertNil(WeChatIdentityResolver.preferredIdentifier(in: a))
    }
}
