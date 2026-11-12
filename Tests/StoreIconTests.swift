import XCTest
@testable import TransferCore

private actor StoreRequests {
    var urls: [URL] = []
    var failFirst: Bool
    let cnOnly: Bool
    init(failFirst: Bool = false, cnOnly: Bool = false) { self.failFirst = failFirst; self.cnOnly = cnOnly }
    func send(_ url: URL) throws -> (Data, Int) {
        urls.append(url)
        if failFirst { failFirst = false; throw URLError(.timedOut) }
        if url.host == "itunes.apple.com" {
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
            let cn = query.contains { $0.name == "country" && $0.value == "cn" }
            if cnOnly && !cn { return (Data("{\"results\":[]}".utf8), 200) }
            return (Data("{\"results\":[{\"bundleId\":\"com.tencent.xin\",\"artworkUrl512\":\"https://is1-ssl.mzstatic.com/icon.png\"}]}".utf8), 200)
        }
        return (Data([1,2,3]), 200)
    }
    func count() -> Int { urls.count }
}
final class StoreIconTests: XCTestCase {
    func testExactIdentityAndAppleOnlyArtwork() throws {
        let wrong = Data("{\"results\":[{\"bundleId\":\"com.other\",\"artworkUrl512\":\"https://is1-ssl.mzstatic.com/a.png\"}]}".utf8)
        XCTAssertNil(try StoreIconLookup.artwork(in: wrong, bundleID: "com.tencent.xin"))
        for text in ["http://is1.mzstatic.com/a", "https://mzstatic.com.evil.test/a", "file:///tmp/a", "https://user@is1.mzstatic.com/a", "https://is1.mzstatic.com:123/a"] {
            XCTAssertFalse(StoreIconLookup.allowedArtwork(URL(string: text)!))
        }
        XCTAssertTrue(StoreIconLookup.allowedArtwork(URL(string: "https://is1-ssl.mzstatic.com/a")!))
    }
    func testInvalidResponsesAndMissingArtworkFail() {
        for json in ["{}", "[]", "not json", "{\"results\":[{\"bundleId\":\"id\",\"artworkUrl512\":\"https://evil.test/a\"}]}"] {
            XCTAssertThrowsError(try StoreIconLookup.artwork(in: Data(json.utf8), bundleID: "id"))
        }
    }
    func testLookupDownloadsExactMatchedArtwork() async throws {
        let mock = StoreRequests()
        let result = try await StoreIconLookup(transport: { try await mock.send($0) }).lookup("com.tencent.xin")
        XCTAssertEqual(result?.data, Data([1,2,3])); XCTAssertEqual(result?.artworkURL.host, "is1-ssl.mzstatic.com")
        let count = await mock.count(); XCTAssertEqual(count, 2)
    }
    func testCountryFallbackAndTransientRetry() async throws {
        let mock = StoreRequests(failFirst: true, cnOnly: true)
        let result = try await StoreIconLookup(transport: { try await mock.send($0) }).lookup("com.tencent.xin")
        XCTAssertNotNil(result)
        let count = await mock.count(); XCTAssertEqual(count, 4)
    }
    func testMissingCloneNeverGuessesParent() async throws {
        let mock = StoreRequests()
        let result = try await StoreIconLookup(transport: { try await mock.send($0) }).lookup("com.tencent.qy.xin")
        XCTAssertNil(result)
        let count = await mock.count(); XCTAssertEqual(count, 2)
    }
    func testHTTPFailureNeverBecomesDefinitiveMiss() async {
        do {
            _ = try await StoreIconLookup(transport: { _ in (Data(), 503) }).lookup("com.tencent.xin")
            XCTFail("Must throw so caller can retry later")
        } catch {}
    }
}
