import Foundation
import XCTest
@testable import LocalShare

final class RemoteSharingTests: XCTestCase {
    func testTokensHave128BitsOfHexEntropy() {
        let token = Token.generate()
        XCTAssertEqual(token.count, 32)
        XCTAssertTrue(token.allSatisfy { "0123456789abcdef".contains($0) })
    }

    func testRemoteSettingsRequireHttpsAndValidSSHPort() {
        let valid = RemoteSettings(publicOrigin: "https://share.example.com", sshHost: "relay.example.com",
                                   sshPort: 2200)
        XCTAssertTrue(valid.isValid)
        XCTAssertEqual(valid.customDomain, "share.example.com")

        XCTAssertFalse(RemoteSettings(publicOrigin: "http://share.example.com", sshHost: "relay.example.com",
                                      sshPort: 2200).isValid)
        XCTAssertFalse(RemoteSettings(publicOrigin: "https://share.example.com/path", sshHost: "relay.example.com",
                                      sshPort: 2200).isValid)
        XCTAssertFalse(RemoteSettings(publicOrigin: "https://share.example.com", sshHost: "relay.example.com",
                                      sshPort: 0).isValid)
    }

    func testTunnelArgumentsStayDirectAndVerifyHostKeys() {
        let settings = RemoteSettings(publicOrigin: "https://share.example.com", sshHost: "relay.example.com",
                                       sshPort: 2200, identityPath: "~/.ssh/localshare")
        let config = settings.tunnelConfiguration(localAddress: "127.0.0.1", localPort: 18081)!
        let args = RemoteTunnel.arguments(for: config)
        XCTAssertTrue(args.contains("StrictHostKeyChecking=yes"))
        XCTAssertTrue(args.contains("-i"))
        XCTAssertTrue(args.contains("\(NSHomeDirectory())/.ssh/localshare"))
        XCTAssertTrue(args.contains(":80:127.0.0.1:18081"))
        XCTAssertEqual(args.suffix(5), ["http", "--proxy_name", "localshare", "--custom_domain", "share.example.com"])
    }

    func testForwardedAddressNeedsTrustedHTTPSProxy() {
        let headers = [
            "x-forwarded-proto": "https",
            "x-forwarded-for": "203.0.113.4, 127.0.0.1",
        ]
        XCTAssertEqual(
            FileServer.forwardedClientAddress(headers: headers, sourceAddress: "127.0.0.1",
                                               remoteEnabled: true, trustedProxyAddresses: ["127.0.0.1"]),
            "203.0.113.4"
        )
        XCTAssertNil(FileServer.forwardedClientAddress(headers: headers, sourceAddress: "192.168.1.2",
                                                       remoteEnabled: true, trustedProxyAddresses: ["127.0.0.1"]))
        XCTAssertNil(FileServer.forwardedClientAddress(headers: ["x-forwarded-proto": "http"],
                                                       sourceAddress: "127.0.0.1", remoteEnabled: true,
                                                       trustedProxyAddresses: ["127.0.0.1"]))
    }
}
