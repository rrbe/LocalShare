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

    func testShareIDGateRejectsRequestsFromPreviousRegistration() {
        XCTAssertTrue(RemoteShareGate.accepts("token-new", currentToken: "token-new"))
        XCTAssertFalse(RemoteShareGate.accepts("token-old", currentToken: "token-new"))
        XCTAssertFalse(RemoteShareGate.accepts(nil, currentToken: "token-new"))
    }

    func testWireProtocolCarriesShareID() throws {
        let raw = try JSONEncoder().encode(RemoteWireMessage(type: "share.start", protocolVersion: 1,
                                                              shareID: "token-new"))
        let decoded = try JSONDecoder().decode(RemoteWireMessage.self, from: raw)
        XCTAssertEqual(decoded.shareID, "token-new")
        XCTAssertTrue(String(decoding: raw, as: UTF8.self).contains("\"share_id\":\"token-new\""))
    }

    func testOnlyAuthenticationCleanupRedirectIsFollowedLocally() {
        let auth = HTTPURLResponse(url: URL(string: "http://127.0.0.1/")!, statusCode: 302,
                                   httpVersion: nil, headerFields: ["Set-Cookie": "ls_token=x; Path=/"])!
        let directory = HTTPURLResponse(url: URL(string: "http://127.0.0.1/folder")!, statusCode: 301,
                                        httpVersion: nil, headerFields: ["Location": "/folder/"])!
        XCTAssertTrue(RemoteRedirectPolicy.shouldFollow(auth))
        XCTAssertFalse(RemoteRedirectPolicy.shouldFollow(directory))
    }

    func testGeneratedPagesKeepNavigationInsideMountedSharePrefix() {
        let file = URL(fileURLWithPath: "/tmp/report.txt")
        let root = DirectoryListing.html(items: [(name: "report.txt", url: file, isDir: false)],
                                         rootName: "Shared", textPreview: "hello", lang: .en)
        XCTAssertTrue(root.contains("href=\"report.txt\""))
        XCTAssertTrue(root.contains("href=\"ls/text\""))
        XCTAssertTrue(root.contains("var LS_ROOT=\"\""))
        XCTAssertFalse(root.contains("href=\"/report.txt\""))
        XCTAssertFalse(root.contains("fetch('/ls/ping"))

        let preview = MarkdownViewer.html(fileName: "readme.md", requestPath: "/docs/readme.md",
                                          crumbs: nil, canUpload: false, lang: .en)
        XCTAssertTrue(preview.contains("var LS_ROOT=\"../\""))
        XCTAssertTrue(preview.contains("fetch(LS_ROOT+'ls/ping'"))
    }
}
