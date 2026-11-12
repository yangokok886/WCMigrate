import Foundation
/// Commit journal bytes before the corresponding destructive operation is issued.
enum DurableJournal {
    static func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
    }
}
