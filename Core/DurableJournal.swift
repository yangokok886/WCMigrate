import Foundation
/// Commit journal bytes before the corresponding destructive operation is issued.
enum DurableJournal {
    static func write(_ data: Data, to url: URL) throws {
        // Foundation's atomic write and FileHandle create temporary Objective-C
        // objects. Drain them here even on a long-running Swift actor worker.
        try autoreleasepool {
            try data.write(to: url, options: .atomic)
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.synchronize()
        }
    }
}
