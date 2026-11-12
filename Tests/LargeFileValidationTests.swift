import XCTest
import Darwin
import CSupport
@testable import TransferCore
final class LargeFileValidationTests: XCTestCase {
    func digest(_ url: URL) throws -> String {
        let input = try FileHandle(forReadingFrom: url); defer { try? input.close() }
        var context = CC_SHA256_CTX(); CC_SHA256_Init(&context)
        while let data = try input.read(upToCount: 4 * 1_048_576), !data.isEmpty {
            data.withUnsafeBytes { _ = CC_SHA256_Update(&context, $0.baseAddress, CC_LONG($0.count)) }
        }
        var bytes = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH)); CC_SHA256_Final(&bytes, &context)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
    func testLargeExchangeAndCopyBenchmark() async throws {
        guard ProcessInfo.processInfo.environment["WCMIGRATE_LARGE_TEST"] == "1" else { throw XCTSkip("Explicit large-file validation; use WCMIGRATE_LARGE_TEST=1") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WCMigrate-Large-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        func app(_ name: String) throws -> AppInstance {
            let path = root.appendingPathComponent(name); try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            return AppInstance(displayName: name, bundleIdentifier: "test." + name, root: path, origin: "benchmark")
        }
        let a = try app("source"), b = try app("target")
        func sparse(_ url: URL, size: UInt64, byte: UInt8) throws {
            XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
            let h = try FileHandle(forWritingTo: url); defer { try? h.close() }
            try h.truncate(atOffset: size)
            for offset in [UInt64(0), size / 2, size - 4096] { try h.seek(toOffset: offset); try h.write(contentsOf: Data(repeating: byte, count: 4096)) }
            try h.synchronize()
        }
        let x = a.root.appendingPathComponent("large.bin"), y = b.root.appendingPathComponent("large.bin")
        try sparse(x, size: 2 * 1_073_741_824 + 17, byte: 0x31)
        try sparse(y, size: 2 * 1_073_741_824 + 31, byte: 0x72)
        let hx = try digest(x), hy = try digest(y)
        var ix = stat(), iy = stat(); XCTAssertEqual(lstat(x.path, &ix), 0); XCTAssertEqual(lstat(y.path, &iy), 0)
        let prefs = PreferencesService(store: root.appendingPathComponent("Copies")), service = DirectMigrationService(store: root.appendingPathComponent("Tasks"))
        let start = Date()
        let result = try await service.migrate(source: a, target: b, mappings: [DirectoryMapping(source: "large.bin", target: "large.bin")], mode: .exchange,
            preferences: prefs, systemVersion: "host", deviceModel: "Mac", allowOverwrite: true, progress: { _ in })
        let exchangeTime = Date().timeIntervalSince(start)
        XCTAssertEqual(result.state, "filesVerified"); XCTAssertEqual(try digest(x), hy); XCTAssertEqual(try digest(y), hx)
        var ax = stat(), ay = stat(); XCTAssertEqual(lstat(x.path, &ax), 0); XCTAssertEqual(lstat(y.path, &ay), 0)
        XCTAssertEqual(ax.st_ino, iy.st_ino); XCTAssertEqual(ay.st_ino, ix.st_ino)
        print("LARGE_EXCHANGE sourceBytes=2147483665 targetBytes=2147483679 seconds=\(exchangeTime) fullSHA256=passed inodeSwap=passed sparse=true")
        try FileManager.default.removeItem(at: x); try FileManager.default.removeItem(at: y)
        let payload = a.root.appendingPathComponent("dense.bin")
        XCTAssertTrue(FileManager.default.createFile(atPath: payload.path, contents: nil))
        let output = try FileHandle(forWritingTo: payload)
        let chunk = Data((0..<(4 * 1_048_576)).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 17) })
        for _ in 0..<64 { try output.write(contentsOf: chunk) }
        try output.synchronize(); try output.close()
        let began = Date()
        _ = try await service.migrate(source: a, target: b, mappings: [DirectoryMapping(source: "dense.bin", target: "dense.bin")], mode: .replace,
            preferences: prefs, systemVersion: "host", deviceModel: "Mac", allowOverwrite: true, progress: { _ in })
        let elapsed = Date().timeIntervalSince(began)
        XCTAssertEqual(try digest(payload), try digest(b.root.appendingPathComponent("dense.bin")))
        print("COPY_BENCHMARK bytes=268435456 seconds=\(elapsed) MiBps=\(256 / elapsed) fullSHA256=passed hostMac=true includesInternalVerification=true")
        let fallback = DirectMigrationService(store: root.appendingPathComponent("FallbackTasks"), preferCloning: false)
        let fallbackStart = Date()
        _ = try await fallback.migrate(source: a, target: b, mappings: [DirectoryMapping(source: "dense.bin", target: "dense-stream.bin")],
            preferences: prefs, systemVersion: "host", deviceModel: "Mac", allowOverwrite: true, progress: { _ in })
        let fallbackElapsed = Date().timeIntervalSince(fallbackStart)
        XCTAssertEqual(try digest(payload), try digest(b.root.appendingPathComponent("dense-stream.bin")))
        print("STREAM_FALLBACK_BENCHMARK bytes=268435456 seconds=\(fallbackElapsed) MiBps=\(256 / fallbackElapsed) fullSHA256=passed forceNoClone=true hostMac=true")

    }
}
