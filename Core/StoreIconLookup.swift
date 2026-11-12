import Foundation

/// Public App Store artwork, never evidence of the installed bundle's contents.
public struct StoreIconResult: Sendable {
    public let data: Data
    public let artworkURL: URL
}
public enum StoreIconError: Error { case invalidResponse, invalidArtwork, tooLarge, http(Int) }
public struct StoreIconLookup: Sendable {
    public typealias Transport = @Sendable (URL) async throws -> (Data, Int)
    private let transport: Transport
    public init(transport: @escaping Transport = { try await StoreIconLookup.fetch($0) }) { self.transport = transport }
    public static func allowedArtwork(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil, url.port == nil,
              let host = url.host?.lowercased() else { return false }
        return host == "mzstatic.com" || host.hasSuffix(".mzstatic.com")
    }
    public static func artwork(in data: Data, bundleID: String) throws -> URL? {
        guard data.count <= 1024 * 1024,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = object["results"] as? [[String: Any]] else { throw StoreIconError.invalidResponse }
        // Do not take the first unrelated search result or guess a clone's original identity.
        guard let app = results.first(where: { ($0["bundleId"] as? String) == bundleID }) else { return nil }
        for key in ["artworkUrl512", "artworkUrl100", "artworkUrl60"] {
            if let text = app[key] as? String, let url = URL(string: text), allowedArtwork(url) { return url }
        }
        throw StoreIconError.invalidArtwork
    }
    public func lookup(_ bundleID: String) async throws -> StoreIconResult? {
        guard !bundleID.isEmpty, bundleID.count <= 255 else { throw StoreIconError.invalidResponse }
        for country in [nil, "cn"] as [String?] {
            var components = URLComponents(string: "https://itunes.apple.com/lookup")!
            components.queryItems = [URLQueryItem(name: "bundleId", value: bundleID), URLQueryItem(name: "entity", value: "software")]
            if let country { components.queryItems?.append(URLQueryItem(name: "country", value: country)) }
            var response: Data?
            for attempt in 0..<2 {
                do {
                    let (data, status) = try await transport(components.url!)
                    guard status == 200 else { throw StoreIconError.http(status) }
                    response = data; break
                } catch {
                    if error is CancellationError { throw error }
                    if attempt == 1 { throw error }
                    try await Task.sleep(nanoseconds: 350_000_000)
                }
            }
            guard let response else { throw StoreIconError.invalidResponse }
            if let url = try Self.artwork(in: response, bundleID: bundleID) {
                let (data, status) = try await transport(url)
                guard status == 200 else { throw StoreIconError.http(status) }
                guard !data.isEmpty, data.count <= 4 * 1024 * 1024 else { throw StoreIconError.tooLarge }
                return StoreIconResult(data: data, artworkURL: url)
            }
        }
        return nil
    }
    public static func fetch(_ url: URL) async throws -> (Data, Int) {
        var request = URLRequest(url: url); request.timeoutInterval = 12
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse,
              let final = response.url,
              (final.host == "itunes.apple.com" && final.scheme == "https") || allowedArtwork(final) else { throw StoreIconError.invalidResponse }
        let limit = url.host == "itunes.apple.com" ? 1024 * 1024 : 4 * 1024 * 1024
        guard response.expectedContentLength <= limit else { throw StoreIconError.tooLarge }
        var data = Data()
        for try await byte in bytes {
            if data.count >= limit { throw StoreIconError.tooLarge }
            data.append(byte)
        }
        return (data, http.statusCode)
    }
}
