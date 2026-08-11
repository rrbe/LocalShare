import XCTest
@testable import LocalShare

final class RemoteSharingTests: XCTestCase {
    func testRemoteSettingsAcceptOnlyBaseServerAddress() {
        XCTAssertTrue(RemoteSettings(serverAddress: "https://ls.example.com").isValid)
        XCTAssertEqual(RemoteSettings(serverAddress: "https://ls.example.com/").serverURL?.absoluteString,
                       "https://ls.example.com")
        XCTAssertTrue(RemoteSettings(serverAddress: "http://127.0.0.1:8080").isValid)
        XCTAssertFalse(RemoteSettings(serverAddress: "").isValid)
        XCTAssertFalse(RemoteSettings(serverAddress: "https://ls.example.com/path").isValid)
        XCTAssertFalse(RemoteSettings(serverAddress: "https://user:pass@ls.example.com").isValid)
        XCTAssertFalse(RemoteSettings(serverAddress: "not a url").isValid)
    }

    func testShareTokenStillHas128BitsOfHexEntropy() {
        let token = Token.generate()
        XCTAssertEqual(token.count, 32)
        XCTAssertTrue(token.allSatisfy { "0123456789abcdef".contains($0) })
    }

    @MainActor func testRemoteDataFrameHasOneLengthPrefix() {
        let frame = RemoteAgent.encodeData("req_1", Data("hello".utf8))
        XCTAssertEqual(Array(frame.prefix(4)), [0, 0, 0, 5])
        XCTAssertEqual(String(data: frame.dropFirst(4).dropFirst(5), encoding: .utf8), "hello")
    }

    @MainActor func testRemotePairStatusUsesUserDefaultsMarker() {
        let key = "remotePairedServerAddress"
        let previous = UserDefaults.standard.object(forKey: key)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults.standard.set("http://127.0.0.1:18080", forKey: key)
        let agent = RemoteAgent()
        XCTAssertTrue(agent.isPaired(for: URL(string: "http://127.0.0.1:18080")))
        XCTAssertFalse(agent.isPaired(for: URL(string: "http://127.0.0.1:18081")))
    }

    func testByteRangesSupportPrefixSuffixAndRejectMultipleRanges() {
        XCTAssertEqual(FileServer.byteRange("bytes=2-5", size: 10)?.start, 2)
        XCTAssertEqual(FileServer.byteRange("bytes=2-5", size: 10)?.end, 5)
        XCTAssertEqual(FileServer.byteRange("bytes=-3", size: 10)?.start, 7)
        XCTAssertEqual(FileServer.byteRange("bytes=8-", size: 10)?.end, 9)
        XCTAssertNil(FileServer.byteRange("bytes=20-", size: 10))
        XCTAssertNil(FileServer.byteRange("bytes=0-1,4-5", size: 10))
    }
}
