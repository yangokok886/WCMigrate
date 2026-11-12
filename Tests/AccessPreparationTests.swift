import XCTest
import Darwin
@testable import TransferCore

final class AccessPreparationTests: XCTestCase {
    func testNestedMetadataCanRecoverBeforeEachAncestorCheck() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let parent = root.appendingPathComponent("Library/Preferences/Plugin/AnimatedEmoji")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let file = parent.appendingPathComponent("test.json")
        try Data("{}".utf8).write(to: file)
        defer { _ = chmod(parent.path, 0o700); try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(chmod(parent.path, 0), 0)
        if geteuid() != 0 {
            XCTAssertThrowsError(try PathSafety.resolve("Library/Preferences/Plugin/AnimatedEmoji/test.json", in: root))
        }
        let resolved = try PathSafety.resolve("Library/Preferences/Plugin/AnimatedEmoji/test.json", in: root, prepareAccess: { url in
            if url.lastPathComponent == "AnimatedEmoji" { _ = chmod(url.path, 0o700) }
        })
        XCTAssertEqual(try Data(contentsOf: resolved), Data("{}".utf8))
    }
    func testAccessPreparationStillRejectsSymlink() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("link").path, withDestinationPath: "/tmp")
        XCTAssertThrowsError(try PathSafety.resolve("link/file", in: root, prepareAccess: { _ in }))
    }
}
