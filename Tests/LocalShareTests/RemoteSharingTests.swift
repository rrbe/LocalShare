import XCTest
import Swifter
import Security
@testable import LocalShare

final class RemoteSharingTests: XCTestCase {
    @MainActor func testRelaySourceIPsReachPresenceAndTextWithoutTrustingVisitorHeaders() async throws {
        let fileServer = FileServer(share: .multiple([]), token: "source-test-token")
        fileServer.listenAddress = "127.0.0.1"
        fileServer.textInboxEnabled = true
        fileServer.remoteTextInboxEnabled = true
        let localPort = try fileServer.start(preferredPorts: [in_port_t(Int.random(in: 42000..<43000))])
        defer { fileServer.stop() }
        let localURL = URL(string: "http://127.0.0.1:\(localPort)")!
        let received = expectation(description: "three remote text deliveries")
        received.expectedFulfillmentCount = 3
        let ended = expectation(description: "all forwarded requests finish")
        ended.expectedFulfillmentCount = 5
        let recorded = SourceRequests()
        fileServer.onReceiveText = { item in
            recorded.append(item)
            if item.text != "LAN" { received.fulfill() }
        }

        let relay = HttpServer()
        relay["/api/v1/enroll"] = { _ in
            .ok(.text("{\"device_id\":\"test\",\"device_token\":\"test-token\"}"))
        }
        relay["/api/v1/agent"] = websocket(text: { socket, raw in
            guard let message = try? JSONDecoder().decode(RemoteWireMessage.self, from: Data(raw.utf8)) else { return }
            if message.type == "share.start" {
                socket.writeText("{\"type\":\"share.ready\",\"share_url\":\"https://share.example.com/share/source-test/\"}")
                // Two browser sessions at one address count once; a second address remains distinct.
                let sources: [String?] = ["203.0.113.10", "203.0.113.10", "2001:db8::20", nil, "203.0.113.10\0invalid"]
                for (index, source) in sources.enumerated() {
                    let request = RemoteWireMessage(type: "request.begin", requestID: "source-\(index)",
                        method: "POST", path: "/ls/text", headers: [RemoteRequestPolicy.clientIPHeader: "203.0.113.250"],
                        clientIP: source, shareID: fileServer.token, body: Data("remote-\(index)".utf8))
                    socket.writeText(String(decoding: try! JSONEncoder().encode(request), as: UTF8.self))
                }
            } else if message.type == "response.begin", let id = message.requestID, let status = message.status {
                recorded.setStatus(status, for: id)
            } else if message.type == "response.end" { ended.fulfill() }
        }, binary: { socket, bytes in
            guard bytes.count >= 4 else { return }
            let length = bytes.prefix(4).reduce(0) { $0 * 256 + Int($1) }
            guard bytes.count >= 4 + length else { return }
            let id = String(decoding: bytes[4..<(4 + length)], as: UTF8.self)
            socket.writeText(String(decoding: try! JSONEncoder().encode(
                RemoteWireMessage(type: "response.ack", requestID: id)), as: UTF8.self))
        }, connected: { $0.writeText("{\"type\":\"hello\",\"protocol\":2}") })
        try relay.start(0, forceIPv4: true)
        defer { relay.stop() }
        let agent = RemoteAgent()
        defer { agent.disconnect() }
        agent.connect(serverURL: URL(string: "http://127.0.0.1:\(try relay.port())")!, enrollmentKey: "test",
                      localBaseURL: localURL, localToken: fileServer.token, deviceName: "Test", lang: .en,
                      persistCredential: false, localRelayToken: fileServer.remoteRequestToken, receivingText: true)
        await fulfillment(of: [received, ended], timeout: 4)
        XCTAssertEqual(recorded.statuses, ["source-0": 200, "source-1": 200, "source-2": 200, "source-3": 400, "source-4": 400])
        XCTAssertEqual(recorded.items.map(\.ip).sorted(), ["203.0.113.10", "203.0.113.10", "2001:db8::20"].sorted())
        XCTAssertEqual(fileServer.activeViewers(), 2)

        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: localURL.appendingPathComponent("ls/text").appending(queryItems: [URLQueryItem(name: "t", value: fileServer.token)]))
        request.timeoutInterval = 3
        request.httpMethod = "POST"
        request.httpBody = Data("LAN".utf8)
        request.setValue("203.0.113.250", forHTTPHeaderField: RemoteRequestPolicy.clientIPHeader)
        request.setValue("visitor-forged", forHTTPHeaderField: "X-LocalShare-Relay")
        let (_, response) = try await session.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(recorded.items.last?.ip, "127.0.0.1")
        XCTAssertEqual(Set(fileServer.activeViewerInfos().map(\.ip)), ["203.0.113.10", "2001:db8::20", "127.0.0.1"])

        request.setValue(fileServer.remoteRequestToken, forHTTPHeaderField: "X-LocalShare-Relay")
        request.setValue("not-an-ip", forHTTPHeaderField: RemoteRequestPolicy.clientIPHeader)
        let (_, invalid) = try await session.data(for: request)
        XCTAssertEqual((invalid as? HTTPURLResponse)?.statusCode, 400)
        XCTAssertEqual(recorded.items.count, 4)
        XCTAssertEqual(fileServer.activeViewers(), 3)
        XCTAssertEqual(agent.status, .connected)
    }

    private final class SourceRequests {
        private let lock = NSLock()
        private var texts: [ReceivedText] = []
        private var responses: [String: Int] = [:]
        var items: [ReceivedText] { lock.withLock { texts } }
        var statuses: [String: Int] { lock.withLock { responses } }
        func append(_ item: ReceivedText) { lock.withLock { texts.append(item) } }
        func setStatus(_ status: Int, for id: String) { lock.withLock { responses[id] = status } }
    }

    func testRemoteSettingsAcceptOnlyBaseServerAddress() {
        XCTAssertTrue(RemoteSettings(serverAddress: "https://ls.example.com").isValid)
        XCTAssertEqual(RemoteSettings(serverAddress: "https://ls.example.com/").serverURL?.absoluteString,
                       "https://ls.example.com")
        XCTAssertTrue(RemoteSettings(serverAddress: "http://127.0.0.1:8080").isValid)
        XCTAssertEqual(RemoteSettings().serverURL?.absoluteString, "https://share.fairydog.net")
        XCTAssertFalse(RemoteSettings(serverAddress: "http://ls.example.com").isValid)
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

    // Keep MainActor-owned objects inside XCTest's async task context during teardown.
    @MainActor func testRemotePairStatusUsesUserDefaultsMarker() async {
        let key = "remotePairedServerAddresses"
        let previous = UserDefaults.standard.object(forKey: key)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults.standard.set(["http://127.0.0.1:18080"], forKey: key)
        let agent = RemoteAgent()
        XCTAssertTrue(agent.isPaired(for: URL(string: "http://127.0.0.1:18080")))
        XCTAssertFalse(agent.isPaired(for: URL(string: "http://127.0.0.1:18081")))
    }

    func testByteRangesSupportPrefixSuffixAndRejectMultipleRanges() {
        XCTAssertEqual(FileServer.byteRange("bytes=2-5", size: 10)?.lowerBound, 2)
        XCTAssertEqual(FileServer.byteRange("bytes=2-5", size: 10)?.upperBound, 5)
        XCTAssertEqual(FileServer.byteRange("bytes=-3", size: 10)?.lowerBound, 7)
        XCTAssertEqual(FileServer.byteRange("bytes=8-", size: 10)?.upperBound, 9)
        XCTAssertNil(FileServer.byteRange("bytes=20-", size: 10))
        XCTAssertNil(FileServer.byteRange("bytes=0-1,4-5", size: 10))
    }

    func testShareIDGateRejectsRequestsFromPreviousRegistration() {
        XCTAssertTrue(RemoteShareGate.accepts("token-new", currentToken: "token-new"))
        XCTAssertFalse(RemoteShareGate.accepts("token-old", currentToken: "token-new"))
        XCTAssertFalse(RemoteShareGate.accepts(nil, currentToken: "token-new"))
    }

    func testWireProtocolCarriesShareID() throws {
        let raw = try JSONEncoder().encode(RemoteWireMessage(type: "share.start", protocolVersion: RemoteWireMessage.version,
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
    @MainActor func testDelayedEnrollmentCannotReconnectAfterDisconnect() async throws {
        let server = HttpServer()
        let enrolled = expectation(description: "enrollment began")
        let socket = expectation(description: "no stale socket")
        socket.isInverted = true
        server["/api/v1/enroll"] = { _ in
            enrolled.fulfill()
            Thread.sleep(forTimeInterval: 0.25)
            return .ok(.text("{\"device_id\":\"test\",\"device_token\":\"stale-test-token\"}"))
        }
        server["/api/v1/agent"] = { _ in socket.fulfill(); return .unauthorized }
        try server.start(0, forceIPv4: true)
        defer { server.stop() }
        let base = URL(string: "http://127.0.0.1:\(try server.port())")!
        let agent = RemoteAgent()
        agent.connect(serverURL: base, enrollmentKey: "test", localBaseURL: base,
                      localToken: "test", deviceName: "Test", lang: .en, persistCredential: false)
        await fulfillment(of: [enrolled], timeout: 2)
        agent.disconnect()
        await fulfillment(of: [socket], timeout: 0.6)
        XCTAssertEqual(agent.status, .disconnected)
        XCTAssertNil(agent.shareBaseURL)
    }

    @MainActor func testUnknownLengthResponsesFinishWithSequentialChunks() async throws {
        let server = HttpServer()
        let body = Data(repeating: 120, count: 40000)
        server["/page"] = { _ in .raw(200, "OK", ["Content-Type": "text/html"]) { try $0.write(body) } }
        server["/empty"] = { _ in .raw(200, "OK", [:], nil) }
        try server.start(0, forceIPv4: true)
        defer { server.stop() }
        let base = URL(string: "http://127.0.0.1:\(try server.port())")!
        for index in 0..<50 {
            let empty = index == 49
            var received = Data()
            var headers = false
            let finished = expectation(description: "response \(index) finished")
            let request = RemoteLocalRequest(id: "test", request: URLRequest(url: base.appendingPathComponent(empty ? "empty" : "page"))) { event in
                switch event {
                case .headers(let status, _): XCTAssertEqual(status, 200); headers = true
                case .data(let chunk):
                    XCTAssertTrue(headers)
                    XCTAssertLessThanOrEqual(chunk.count, 65536)
                    received.append(chunk)
                    try await Task.sleep(nanoseconds: 1_000_000)
                case .finished(let error): XCTAssertNil(error); finished.fulfill()
                }
            }
            request.start()
            await fulfillment(of: [finished], timeout: 2)
            request.cancel()
            XCTAssertEqual(received, empty ? Data() : body)
        }
    }

    @MainActor func testSameSessionUpdatesKeepPublishedURL() async throws {
        let server = HttpServer()
        let ready = expectation(description: "share ready")
        let permission = expectation(description: "permission updated")
        let republished = expectation(description: "same session must not republish")
        republished.isInverted = true
        var first = true
        server["/api/v1/enroll"] = { _ in .ok(.text("{\"device_id\":\"test\",\"device_token\":\"test-token\"}")) }
        server["/api/v1/agent"] = websocket(text: { socket, raw in
            guard let message = try? JSONDecoder().decode(RemoteWireMessage.self, from: Data(raw.utf8)) else { return }
            if message.type == "share.start" {
                if first { first = false } else { republished.fulfill() }
                socket.writeText("{\"type\":\"share.ready\",\"share_url\":\"https://share.example.com/share/test/\"}")
            } else if message.type == "share.update" {
                XCTAssertEqual(message.shareID, "local-session")
                XCTAssertEqual(message.textInbox, true)
                permission.fulfill()
            }
        }, connected: { $0.writeText("{\"type\":\"hello\",\"protocol\":2}") })
        try server.start(0, forceIPv4: true)
        defer { server.stop() }
        let base = URL(string: "http://127.0.0.1:\(try server.port())")!
        let agent = RemoteAgent()
        defer { agent.disconnect() }
        agent.onShareURLChange = { if $0 != nil { ready.fulfill() } }
        agent.connect(serverURL: base, enrollmentKey: "test", localBaseURL: base,
                      localToken: "local-session", deviceName: "Test", lang: .en, persistCredential: false)
        await fulfillment(of: [ready], timeout: 2)
        let previous = agent.shareBaseURL
        agent.updateLocalShare(baseURL: base, token: "local-session")
        agent.updateReceivingText(true)
        await fulfillment(of: [permission, republished], timeout: 0.3)
        XCTAssertEqual(agent.shareBaseURL, previous)
    }

    @MainActor func testProtocolMismatchStopsConnection() async throws {
        let server = HttpServer()
        server["/api/v1/enroll"] = { _ in .ok(.text("{\"device_id\":\"test\",\"device_token\":\"test-token\"}")) }
        server["/api/v1/agent"] = websocket(connected: { $0.writeText("{\"type\":\"hello\",\"protocol\":1}") })
        try server.start(0, forceIPv4: true)
        defer { server.stop() }
        let base = URL(string: "http://127.0.0.1:\(try server.port())")!
        let rejected = expectation(description: "protocol rejected")
        let agent = RemoteAgent()
        defer { agent.disconnect() }
        agent.onStateChange = { status, error in if status == .disconnected && error != nil { rejected.fulfill() } }
        agent.connect(serverURL: base, enrollmentKey: "test", localBaseURL: base,
                      localToken: "local-session", deviceName: "Test", lang: .en, persistCredential: false)
        await fulfillment(of: [rejected], timeout: 2)
        XCTAssertEqual(agent.lastError, L.remoteProtocolMismatch(.en))
        XCTAssertNil(agent.shareBaseURL)
    }

    @MainActor func testInvalidDeviceCredentialStopsRetries() async throws {
        let server = HttpServer()
        server["/api/v1/enroll"] = { _ in .ok(.text("{\"device_id\":\"test\",\"device_token\":\"revoked-token\"}")) }
        server["/api/v1/agent"] = { _ in .unauthorized }
        try server.start(0, forceIPv4: true)
        defer { server.stop() }
        let base = URL(string: "http://127.0.0.1:\(try server.port())")!
        let rejected = expectation(description: "invalid credential is terminal")
        let agent = RemoteAgent()
        defer { agent.disconnect() }
        agent.onStateChange = { status, error in
            if status == .disconnected && error != nil { rejected.fulfill() }
        }
        agent.connect(serverURL: base, enrollmentKey: "test", localBaseURL: base,
                      localToken: "test", deviceName: "Test", lang: .en, persistCredential: false)
        await fulfillment(of: [rejected], timeout: 2)
        XCTAssertEqual(agent.status, .disconnected)
        XCTAssertEqual(agent.lastError, L.remoteInvalidCredentials(.en))
    }

    @MainActor func testSwitchingServerDuringEnrollmentDiscardsOldCredentials() async throws {
        let oldServer = HttpServer(), newServer = HttpServer()
        let oldEnrollment = expectation(description: "old enrollment began")
        let oldSocket = expectation(description: "old service must not connect")
        oldSocket.isInverted = true
        oldServer["/api/v1/enroll"] = { _ in
            oldEnrollment.fulfill()
            Thread.sleep(forTimeInterval: 0.25)
            return .ok(.text("{\"device_id\":\"old\",\"device_token\":\"old-token\"}"))
        }
        oldServer["/api/v1/agent"] = { _ in oldSocket.fulfill(); return .unauthorized }
        newServer["/api/v1/enroll"] = { _ in .ok(.text("{\"device_id\":\"new\",\"device_token\":\"new-token\"}")) }
        let handler = websocket(text: { socket, raw in
            if (try? JSONDecoder().decode(RemoteWireMessage.self, from: Data(raw.utf8)))?.type == "share.start" {
                socket.writeText("{\"type\":\"share.ready\",\"share_url\":\"https://new.example.com/share/current/\"}")
            }
        }, connected: { $0.writeText("{\"type\":\"hello\",\"protocol\":2}") })
        newServer["/api/v1/agent"] = { request in
            XCTAssertEqual(request.headers["authorization"], "Bearer new-token")
            return handler(request)
        }
        try oldServer.start(0, forceIPv4: true)
        try newServer.start(0, forceIPv4: true)
        defer { oldServer.stop(); newServer.stop() }
        let oldBase = URL(string: "http://127.0.0.1:\(try oldServer.port())")!
        let newBase = URL(string: "http://127.0.0.1:\(try newServer.port())")!
        let agent = RemoteAgent()
        defer { agent.disconnect() }
        agent.connect(serverURL: oldBase, enrollmentKey: "old", localBaseURL: oldBase,
                      localToken: "test", deviceName: "Test", lang: .en, persistCredential: false)
        await fulfillment(of: [oldEnrollment], timeout: 2)
        let ready = expectation(description: "new share ready")
        agent.onShareURLChange = { if $0 != nil { ready.fulfill() } }
        agent.connect(serverURL: newBase, enrollmentKey: "new", localBaseURL: newBase,
                      localToken: "test", deviceName: "Test", lang: .en, persistCredential: false)
        await fulfillment(of: [ready, oldSocket], timeout: 0.6)
        XCTAssertEqual(agent.shareBaseURL, "https://new.example.com/share/current/")
        let reused = expectation(description: "new credential remains reusable")
        agent.onShareURLChange = { if $0 != nil { reused.fulfill() } }
        agent.connect(serverURL: newBase, enrollmentKey: "", localBaseURL: newBase,
                      localToken: "test", deviceName: "Test", lang: .en, persistCredential: false)
        await fulfillment(of: [reused], timeout: 2)
    }

    @MainActor func testForgettingDuringEnrollmentCannotRestoreKeychainCredential() async throws {
        let server = HttpServer()
        let began = expectation(description: "enrollment began")
        let socket = expectation(description: "forgotten service stays disconnected")
        socket.isInverted = true
        server["/api/v1/enroll"] = { _ in
            began.fulfill()
            Thread.sleep(forTimeInterval: 0.25)
            return .ok(.text("{\"device_id\":\"forgotten\",\"device_token\":\"forgotten-token\"}"))
        }
        server["/api/v1/agent"] = { _ in socket.fulfill(); return .unauthorized }
        try server.start(0, forceIPv4: true)
        defer { server.stop() }
        let base = URL(string: "http://127.0.0.1:\(try server.port())")!
        let account = RemoteKeychain.deviceAccount(for: base)
        try XCTSkipIf(try RemoteKeychain.value(for: account) != nil, "ephemeral test address already has a credential")
        let marker = "remotePairedServerAddresses"
        let previous = UserDefaults.standard.object(forKey: marker)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: marker) }
            else { UserDefaults.standard.removeObject(forKey: marker) }
        }
        let agent = RemoteAgent()
        agent.connect(serverURL: base, enrollmentKey: "test", localBaseURL: base,
                      localToken: "test", deviceName: "Test", lang: .en)
        await fulfillment(of: [began], timeout: 2)
        try agent.forgetDevice(for: base)
        await fulfillment(of: [socket], timeout: 0.6)
        XCTAssertNil(try RemoteKeychain.value(for: account))
        XCTAssertFalse(agent.isPaired(for: base))
        XCTAssertEqual(agent.status, .disconnected)
    }

    @MainActor func testDisconnectAndExpiryCancelQueuedRetries() async throws {
        for expires in [false, true] {
            let server = HttpServer()
            server["/api/v1/enroll"] = { _ in .ok(.text("{\"device_id\":\"test\",\"device_token\":\"test-token\"}")) }
            let retrying = expectation(description: "retry queued")
            let reopened = expectation(description: "manual disconnect cancels retry")
            reopened.isInverted = true
            let lock = NSLock()
            var connections = 0
            let handler = websocket(text: { socket, raw in
                if (try? JSONDecoder().decode(RemoteWireMessage.self, from: Data(raw.utf8)))?.type == "share.start" {
                    socket.writeCloseFrame()
                }
            }, connected: { $0.writeText("{\"type\":\"hello\",\"protocol\":2}") })
            server["/api/v1/agent"] = { request in
                lock.withLock { connections += 1; if connections > 1 { reopened.fulfill() } }
                return handler(request)
            }
            try server.start(0, forceIPv4: true)
            defer { server.stop() }
            let base = URL(string: "http://127.0.0.1:\(try server.port())")!
            let agent = RemoteAgent()
            agent.onStateChange = { status, _ in if status == .reconnecting { retrying.fulfill() } }
            agent.connect(serverURL: base, enrollmentKey: "test", localBaseURL: base,
                          localToken: "test", deviceName: "Test", lang: .en, persistCredential: false)
            await fulfillment(of: [retrying], timeout: 2)
            if expires {
                let deadline = ShareAutoStop()
                let stopped = expectation(description: "deadline stops remote retry")
                deadline.onExpire = { agent.disconnect(); stopped.fulfill() }
                deadline.schedule(at: Date().addingTimeInterval(0.05))
                await fulfillment(of: [stopped], timeout: 2)
            } else {
                agent.disconnect()
            }
            await fulfillment(of: [reopened], timeout: 1.2)
            XCTAssertEqual(agent.status, .disconnected)
        }
    }

    @MainActor func testTemporaryDisconnectionReconnectsWithSameCredential() async throws {
        let server = HttpServer()
        let enrollment = expectation(description: "only one enrollment")
        server["/api/v1/enroll"] = { _ in
            enrollment.fulfill()
            return .ok(.text("{\"device_id\":\"test\",\"device_token\":\"test-token\"}"))
        }
        let lock = NSLock()
        var starts = 0
        server["/api/v1/agent"] = websocket(text: { socket, raw in
            guard (try? JSONDecoder().decode(RemoteWireMessage.self, from: Data(raw.utf8)))?.type == "share.start" else { return }
            let attempt = lock.withLock { starts += 1; return starts }
            if attempt == 1 { socket.writeCloseFrame() }
            else { socket.writeText("{\"type\":\"share.ready\",\"share_url\":\"https://share.example.com/share/reconnected/\"}") }
        }, connected: { $0.writeText("{\"type\":\"hello\",\"protocol\":2}") })
        try server.start(0, forceIPv4: true)
        defer { server.stop() }
        let base = URL(string: "http://127.0.0.1:\(try server.port())")!
        let ready = expectation(description: "reconnected share")
        let agent = RemoteAgent()
        defer { agent.disconnect() }
        agent.onShareURLChange = { if $0 != nil { ready.fulfill() } }
        agent.connect(serverURL: base, enrollmentKey: "test", localBaseURL: base,
                      localToken: "test", deviceName: "Test", lang: .en, persistCredential: false)
        await fulfillment(of: [enrollment, ready], timeout: 3)
        XCTAssertEqual(agent.status, .connected)
        XCTAssertEqual(lock.withLock { starts }, 2)
    }

    @MainActor func testWaitingForKeychainDoesNotBlockDisconnectOrOpenAStaleSocket() async throws {
        let server = HttpServer()
        let readStarted = expectation(description: "keychain read started")
        let readFinished = expectation(description: "keychain read finished")
        let socket = expectation(description: "canceled keychain result cannot open a socket")
        socket.isInverted = true
        server["/api/v1/agent"] = { _ in socket.fulfill(); return .unauthorized }
        try server.start(0, forceIPv4: true)
        defer { server.stop() }
        let unblockRead = DispatchSemaphore(value: 0)
        let agent = RemoteAgent(credentialReader: { _ in
            readStarted.fulfill()
            _ = unblockRead.wait(timeout: .now() + 2)
            readFinished.fulfill()
            return "delayed-test-token"
        })
        defer { unblockRead.signal(); agent.disconnect() }
        let base = URL(string: "http://127.0.0.1:\(try server.port())")!
        let startedAt = ProcessInfo.processInfo.systemUptime
        agent.connect(serverURL: base, enrollmentKey: "", localBaseURL: base,
                      localToken: "test", deviceName: "Test", lang: .en)
        await fulfillment(of: [readStarted], timeout: 1)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - startedAt, 1,
                          "a pending security prompt must leave the main actor available")
        agent.disconnect()
        XCTAssertEqual(agent.status, .disconnected)
        unblockRead.signal()
        await fulfillment(of: [readFinished, socket], timeout: 0.3)
        XCTAssertEqual(agent.status, .disconnected)
        XCTAssertNil(agent.shareBaseURL)
    }

    @MainActor func testDeniedKeychainReadDoesNotRegisterAnotherDevice() async throws {
        let server = HttpServer()
        let registration = expectation(description: "access denied is not a missing credential")
        registration.isInverted = true
        server["/api/v1/register"] = { _ in registration.fulfill(); return .unauthorized }
        try server.start(0, forceIPv4: true)
        defer { server.stop() }
        let agent = RemoteAgent(credentialReader: { _ in
            throw RemoteKeychain.Failure(status: errSecAuthFailed)
        })
        defer { agent.disconnect() }
        let denied = expectation(description: "credential access failure shown")
        agent.onStateChange = { status, error in
            if status == .disconnected, error != nil { denied.fulfill() }
        }
        let base = URL(string: "http://127.0.0.1:\(try server.port())")!
        agent.connect(serverURL: base, enrollmentKey: "", localBaseURL: base,
                      localToken: "test", deviceName: "Test", lang: .en, automaticRegistration: true)
        await fulfillment(of: [denied, registration], timeout: 0.3)
        XCTAssertEqual(agent.status, .disconnected)
        XCTAssertNotEqual(agent.lastError, L.remoteEnrollmentRequired(.en))
    }

    @MainActor func testConnectionRefusedDuringOutageStillReconnects() async throws {
        let firstServer = HttpServer(), restoredServer = HttpServer()
        let enrollment = expectation(description: "only one enrollment")
        firstServer["/api/v1/enroll"] = { _ in
            enrollment.fulfill()
            return .ok(.text("{\"device_id\":\"test\",\"device_token\":\"test-token\"}"))
        }
        for server in [firstServer, restoredServer] {
            server["/api/v1/agent"] = websocket(text: { socket, raw in
                guard (try? JSONDecoder().decode(RemoteWireMessage.self, from: Data(raw.utf8)))?.type == "share.start" else { return }
                socket.writeText("{\"type\":\"share.ready\",\"share_url\":\"https://share.example.com/share/restored/\"}")
            }, connected: { $0.writeText("{\"type\":\"hello\",\"protocol\":2}") })
        }
        try firstServer.start(0, forceIPv4: true)
        defer { firstServer.stop(); restoredServer.stop() }
        let port = try firstServer.port()
        let base = URL(string: "http://127.0.0.1:\(port)")!
        let firstReady = expectation(description: "initial share")
        let restored = expectation(description: "share restored after refused retry")
        let agent = RemoteAgent()
        defer { agent.disconnect() }
        var publications = 0
        agent.onShareURLChange = { url in
            guard url != nil else { return }
            publications += 1
            if publications == 1 { firstReady.fulfill() }
            else if publications == 2 { restored.fulfill() }
        }
        agent.connect(serverURL: base, enrollmentKey: "test", localBaseURL: base,
                      localToken: "test", deviceName: "Test", lang: .en, persistCredential: false)
        await fulfillment(of: [enrollment, firstReady], timeout: 2)
        firstServer.stop()
        // Keep the listener closed through the first automatic retry.
        try await Task.sleep(nanoseconds: 1_400_000_000)
        XCTAssertEqual(agent.status, .reconnecting)
        XCTAssertNil(agent.shareBaseURL)
        try restoredServer.start(UInt16(port), forceIPv4: true)
        await fulfillment(of: [restored], timeout: 4)
        XCTAssertEqual(agent.status, .connected)
    }

    @MainActor func testStoredCredentialsAreReusedAndForgottenPerServer() async throws {
        var keychain: SecKeychain?
        var keychainStatus: SecKeychainStatus = 0
        try XCTSkipIf(SecKeychainCopyDefault(&keychain) != errSecSuccess ||
                      SecKeychainGetStatus(keychain, &keychainStatus) != errSecSuccess ||
                      keychainStatus & SecKeychainStatus(kSecUnlockStateStatus) == 0,
                      "login keychain must be unlocked for credential integration testing")
        let firstServer = HttpServer(), secondServer = HttpServer()
        let lock = NSLock()
        var registrations = 0
        for (server, token) in [(firstServer, "first-test-token"), (secondServer, "second-test-token")] {
            server["/api/v1/register"] = { _ in
                lock.withLock { registrations += 1 }
                return .ok(.text("{\"device_id\":\"test\",\"device_token\":\"\(token)\"}"))
            }
            let handler = websocket(text: { socket, raw in
                if (try? JSONDecoder().decode(RemoteWireMessage.self, from: Data(raw.utf8)))?.type == "share.start" {
                    socket.writeText("{\"type\":\"share.ready\",\"share_url\":\"https://share.example.com/share/test/\"}")
                }
            }, connected: { $0.writeText("{\"type\":\"hello\",\"protocol\":2}") })
            server["/api/v1/agent"] = { request in
                XCTAssertEqual(request.headers["authorization"], "Bearer \(token)")
                return handler(request)
            }
            try server.start(0, forceIPv4: true)
        }
        defer { firstServer.stop(); secondServer.stop() }
        let first = URL(string: "http://127.0.0.1:\(try firstServer.port())")!
        let second = URL(string: "http://127.0.0.1:\(try secondServer.port())")!
        let accounts = [first, second].map(RemoteKeychain.deviceAccount)
        for account in accounts {
            try XCTSkipIf(try RemoteKeychain.value(for: account) != nil, "ephemeral test address already has a credential")
        }
        let marker = "remotePairedServerAddresses"
        let previous = UserDefaults.standard.object(forKey: marker)
        defer {
            for account in accounts {
                do { try RemoteKeychain.remove(for: account) }
                catch { XCTFail("test credential cleanup failed: \(error)") }
            }
            if let previous { UserDefaults.standard.set(previous, forKey: marker) }
            else { UserDefaults.standard.removeObject(forKey: marker) }
        }
        for base in [first, second] {
            let ready = expectation(description: "registered service")
            let agent = RemoteAgent()
            agent.onShareURLChange = { if $0 != nil { ready.fulfill() } }
            agent.connect(serverURL: base, enrollmentKey: "", localBaseURL: base,
                          localToken: "test", deviceName: "Test", lang: .en, automaticRegistration: true)
            await fulfillment(of: [ready], timeout: 2)
            agent.disconnect()
        }
        let freshAgent = RemoteAgent()
        defer { freshAgent.disconnect() }
        XCTAssertEqual(freshAgent.status, .disconnected)
        let reused = expectation(description: "stored credential reused")
        freshAgent.onShareURLChange = { if $0 != nil { reused.fulfill() } }
        freshAgent.connect(serverURL: first, enrollmentKey: "", localBaseURL: first,
                           localToken: "test", deviceName: "Test", lang: .en, automaticRegistration: true)
        await fulfillment(of: [reused], timeout: 2)
        XCTAssertEqual(lock.withLock { registrations }, 2)
        try freshAgent.forgetDevice(for: first)
        XCTAssertNil(try RemoteKeychain.value(for: accounts[0]))
        XCTAssertEqual(try RemoteKeychain.value(for: accounts[1]), "second-test-token")
        XCTAssertFalse(freshAgent.isPaired(for: first))
        XCTAssertTrue(freshAgent.isPaired(for: second))
        let registeredAgain = expectation(description: "forgotten service registers again")
        freshAgent.onShareURLChange = { if $0 != nil { registeredAgain.fulfill() } }
        freshAgent.connect(serverURL: first, enrollmentKey: "", localBaseURL: first,
                           localToken: "test", deviceName: "Test", lang: .en, automaticRegistration: true)
        await fulfillment(of: [registeredAgain], timeout: 2)
        XCTAssertEqual(lock.withLock { registrations }, 3)
    }

    @MainActor func testRegistrationQuotaIsReportedWithoutRetrying() async throws {
        let server = HttpServer()
        server["/api/v1/register"] = { _ in .raw(429, "Too Many Requests", [:], nil) }
        let socket = expectation(description: "quota denial must not open a socket")
        socket.isInverted = true
        server["/api/v1/agent"] = { _ in socket.fulfill(); return .unauthorized }
        try server.start(0, forceIPv4: true)
        defer { server.stop() }
        let base = URL(string: "http://127.0.0.1:\(try server.port())")!
        let rejected = expectation(description: "quota rejected")
        let agent = RemoteAgent()
        defer { agent.disconnect() }
        agent.onStateChange = { status, error in if status == .disconnected && error != nil { rejected.fulfill() } }
        agent.connect(serverURL: base, enrollmentKey: "", localBaseURL: base,
                      localToken: "test", deviceName: "Test", lang: .zh, persistCredential: false, automaticRegistration: true)
        await fulfillment(of: [rejected, socket], timeout: 0.3)
        XCTAssertEqual(agent.lastError, L.remoteLimitReached(.zh))
    }

    @MainActor func testEnrollmentRedirectCannotSendCredentialToAnotherServer() async throws {
        let server = HttpServer(), destination = HttpServer()
        let leaked = expectation(description: "redirect must not receive enrollment")
        leaked.isInverted = true
        destination["/api/v1/enroll"] = { _ in leaked.fulfill(); return .unauthorized }
        try destination.start(0, forceIPv4: true)
        defer { destination.stop() }
        let target = "http://127.0.0.1:\(try destination.port())/api/v1/enroll"
        server["/api/v1/enroll"] = { _ in .raw(307, "Temporary Redirect", ["Location": target], nil) }
        try server.start(0, forceIPv4: true)
        defer { server.stop() }
        let base = URL(string: "http://127.0.0.1:\(try server.port())")!
        let rejected = expectation(description: "redirect rejected")
        let agent = RemoteAgent()
        defer { agent.disconnect() }
        agent.onStateChange = { status, error in if status == .disconnected && error != nil { rejected.fulfill() } }
        agent.connect(serverURL: base, enrollmentKey: "private-test-key", localBaseURL: base,
                      localToken: "test", deviceName: "Test", lang: .en, persistCredential: false)
        await fulfillment(of: [rejected, leaked], timeout: 0.3)
        XCTAssertEqual(agent.lastError, L.remoteEnrollmentRejected(.en))
    }

}
