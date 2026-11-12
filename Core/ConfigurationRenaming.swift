import Foundation
import Darwin
#if canImport(CSupport)
import CSupport
#endif

/// Rename only a known application's own preference domain, never arbitrary plugin domains.
public struct ConfigurationRename: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID = UUID()
    public var root: URL
    public var source: String
    public var destination: String
    public init(root: URL, source: String, destination: String) {
        self.root = root; self.source = source; self.destination = destination
    }
    public static func plan(source: AppInstance, target: AppInstance, mappings: [DirectoryMapping],
                            preferencesPath: String = "Library/Preferences") -> [Self] {
        let from = source.bundleIdentifier, to = target.bundleIdentifier
        func valid(_ id: String) -> Bool {
            id.contains(".") && !id.contains("/") && id.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || ".-_".unicodeScalars.contains($0) }
        }
        guard valid(from), valid(to), from != to else { return [] }
        let original = preferencesPath + "/" + from + ".plist"
        return mappings.compactMap { mapping in
            let relative: String
            if mapping.source == original { relative = "" }
            else if original.hasPrefix(mapping.source + "/") { relative = String(original.dropFirst(mapping.source.count + 1)) }
            else { return nil }
            let incoming = mapping.target + (relative.isEmpty ? "" : "/" + relative)
            guard URL(fileURLWithPath: incoming).lastPathComponent == from + ".plist" else { return nil }
            let destination = (incoming as NSString).deletingLastPathComponent + "/" + to + ".plist"
            return Self(root: target.root, source: incoming, destination: destination)
        }
    }
}

/// Separate from migration receipts: renaming never invalidates a resumable copy/exchange plan.
/// POSIX rename atomically replaces the destination. Persisted entries survive app termination.
public actor ConfigurationRenameQueue {
    private struct Entry: Codable { var item: ConfigurationRename; var bytes: Int64; var device: UInt64; var inode: UInt64; var digest: Data; var previousDestination: Data? }
    private let file: URL
    private let prepare: @Sendable (URL) -> Void
    public init(file: URL, prepareAccess: @escaping @Sendable (URL) -> Void = { _ in }) { self.file = file; prepare = prepareAccess }
    private func read() throws -> [Entry] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        return try JSONDecoder().decode([Entry].self, from: Data(contentsOf: file))
    }
    private func write(_ entries: [Entry]) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(entries).write(to: file, options: .atomic)
    }
    public func pending() throws -> [ConfigurationRename] { try read().map(\.item) }
    public func enqueue(_ items: [ConfigurationRename]) throws -> [ConfigurationRename] {
        var entries = try read(); var added: [ConfigurationRename] = []
        for item in items {
            let source = try PathSafety.potential(item.source, in: item.root, prepareAccess: prepare)
            let destination = try PathSafety.potential(item.destination, in: item.root, prepareAccess: prepare)
            prepare(source); var info = stat()
            if lstat(source.path, &info) != 0 {
                if errno == ENOENT { continue }
                throw PathDiagnostic.system("读取待改名配置", source.path, code: errno)
            }
            guard XCTModeIsRegular(UInt32(info.st_mode)) != 0 else { throw TransferError.unsupportedFile }
            // Content must actually be a plist; directory names alone are insufficient.
            guard info.st_size <= 16 * 1024 * 1024 else { throw TransferError.unsupportedFile }
            let content = try Data(contentsOf: source)
            _ = try PropertyListSerialization.propertyList(from: content, options: [], format: nil)
            let previous = try destinationFingerprint(destination)
            if entries.contains(where: { $0.item.root == item.root && $0.item.source == item.source }) { continue }
            entries.append(Entry(item: item, bytes: info.st_size, device: UInt64(info.st_dev), inode: UInt64(info.st_ino), digest: digest(content), previousDestination: previous)); added.append(item)
        }
        try write(entries); return added
    }
    private func digest(_ content: Data) -> Data {
        var context = CC_SHA256_CTX(); CC_SHA256_Init(&context)
        content.withUnsafeBytes { _ = CC_SHA256_Update(&context, $0.baseAddress, CC_LONG($0.count)) }
        var bytes = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        CC_SHA256_Final(&bytes, &context); return Data(bytes)
    }
    private func destinationFingerprint(_ url: URL) throws -> Data? {
        prepare(url); var info = stat()
        if lstat(url.path, &info) != 0 {
            if errno == ENOENT { return nil }
            throw PathDiagnostic.system("读取配置改名目标", url.path, code: errno)
        }
        guard XCTModeIsRegular(UInt32(info.st_mode)) != 0, info.st_size <= 16 * 1024 * 1024 else { throw TransferError.unsupportedFile }
        return digest(try Data(contentsOf: url))
    }
    public func discard(_ ids: Set<UUID>) throws { try write(read().filter { !ids.contains($0.item.id) }) }
    public func apply(_ ids: Set<UUID>) throws -> Int {
        var entries = try read(); var count = 0
        for entry in entries.filter({ ids.contains($0.item.id) }) {
            let item = entry.item
            let source = try PathSafety.potential(item.source, in: item.root, prepareAccess: prepare)
            let destination = try PathSafety.potential(item.destination, in: item.root, prepareAccess: prepare)
            prepare(source); prepare(destination); var info = stat()
            if lstat(source.path, &info) != 0 {
                // A prior atomic rename may have completed immediately before process death.
                var result = stat()
                guard errno == ENOENT, lstat(destination.path, &result) == 0,
                      UInt64(result.st_ino) == entry.inode, UInt64(result.st_dev) == entry.device,
                      result.st_size == entry.bytes, try destinationFingerprint(destination) == entry.digest else { throw MigrationFailure.changed }
            } else {
                guard XCTModeIsRegular(UInt32(info.st_mode)) != 0, UInt64(info.st_ino) == entry.inode,
                      UInt64(info.st_dev) == entry.device, info.st_size == entry.bytes, try destinationFingerprint(source) == entry.digest else { throw MigrationFailure.changed }
                guard try destinationFingerprint(destination) == entry.previousDestination else { throw MigrationFailure.changed }
                // Do not replace a directory or follow a symlink at the target.
                var other = stat()
                if lstat(destination.path, &other) == 0 {
                    guard XCTModeIsRegular(UInt32(other.st_mode)) != 0 else { throw TransferError.unsupportedFile }
                } else if errno != ENOENT { throw PathDiagnostic.system("读取改名目标", destination.path, code: errno) }
                guard rename(source.path, destination.path) == 0 else { throw PathDiagnostic.system("配置改名", destination.path, code: errno) }
            }
            entries.removeAll { $0.item.id == item.id }; try write(entries); count += 1
        }
        return count
    }
}
