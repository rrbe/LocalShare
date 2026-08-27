import XCTest
@testable import LocalShare

final class TailscaleInfoTests: XCTestCase {
    func testTailscaleIPv4RangeBoundaries() {
        XCTAssertTrue(NetworkInfo.isTailscaleIPv4("100.64.0.0"))
        XCTAssertTrue(NetworkInfo.isTailscaleIPv4("100.127.255.255"))
        XCTAssertFalse(NetworkInfo.isTailscaleIPv4("100.63.255.255"))
        XCTAssertFalse(NetworkInfo.isTailscaleIPv4("100.128.0.0"))
        XCTAssertFalse(NetworkInfo.isTailscaleIPv4("192.168.1.2"))
        XCTAssertFalse(NetworkInfo.isTailscaleIPv4("100.64.999.1"))
    }

    func testServerRejectsTailscaleClientsUntilEnabled() {
        XCTAssertFalse(FileServer.allowsClient(address: "100.100.2.3", tailscaleAccessEnabled: false))
        XCTAssertTrue(FileServer.allowsClient(address: "100.100.2.3", tailscaleAccessEnabled: true))
        XCTAssertTrue(FileServer.allowsClient(address: "192.168.1.8", tailscaleAccessEnabled: false))
        XCTAssertTrue(FileServer.allowsClient(address: nil, tailscaleAccessEnabled: false))
    }

    func testStatusParserFindsIPv4AndMagicDNSName() {
        let json = #"{"Self":{"DNSName":"macbook.example.ts.net.","TailscaleIPs":["100.72.3.4","fd7a:115c:a1e0::1"]}}"#
        XCTAssertEqual(TailscaleInfo.parseStatus(Data(json.utf8)),
                       TailscaleStatus(ipv4: "100.72.3.4", dnsName: "macbook.example.ts.net"))
    }

    func testStatusParserRequiresTailscaleIPv4() {
        let json = #"{"Self":{"DNSName":"macbook.example.ts.net.","TailscaleIPs":["10.0.0.2"]}}"#
        XCTAssertNil(TailscaleInfo.parseStatus(Data(json.utf8)))
    }

    func testPublicRelayAddressKeepsOpaqueServerURL() {
        let url = "https://share.example/opaque-route"
        let address = ShareAddress(kind: .publicRelay, scope: .publicInternet, url: url)
        XCTAssertEqual(address.url, url)
    }
}
