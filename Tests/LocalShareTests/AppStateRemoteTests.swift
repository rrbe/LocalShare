import XCTest
import Combine
import Security
import Swifter
@testable import LocalShare

final class AppStateRemoteTests: XCTestCase {
    @MainActor func testAccessCodeAddressesKeepAuthenticatedQRCodes() async throws {
        let preferences = Preferences()
        defer { preferences.restore() }
        let state = AppState()
        defer { state.stop() }
        state.setSharedText("demo")
        state.selectedInterface = NetworkInterface(name: "en0", ip: "192.168.1.2")
        state.setAccessCodeEnabled(true)

        let address = try XCTUnwrap(state.shareAddresses.first { $0.kind == .localIP })
        XCTAssertEqual(address.url, "http://192.168.1.2:\(state.port)")
        XCTAssertEqual(address.qrURL, "http://192.168.1.2:\(state.port)/ls/text?t=\(state.token)")
        XCTAssertEqual(state.primaryURL, address.qrURL)
        XCTAssertEqual(state.presentedURL, address.url)

        if let hostname = state.shareAddresses.first(where: { $0.kind == .localHostname }) {
            state.selectShareAddress(.localHostname)
            XCTAssertEqual(state.primaryURL, hostname.qrURL)
            XCTAssertEqual(state.presentedURL, hostname.url)
            XCTAssertTrue(hostname.qrURL.contains("?t=\(state.token)"))
        }
        let selected = state.selectedAddressKind
        state.selectShareAddress(.publicRelay)
        XCTAssertEqual(state.selectedAddressKind, selected, "unavailable addresses cannot be selected")
        state.stop()
        XCTAssertNil(state.primaryURL)
        XCTAssertTrue(state.shareAddresses.isEmpty)
    }

    @MainActor func testCustomServerRegistersAndReusesCredentialsWithBlankKey() async throws {
        var keychain: SecKeychain?
        var status = SecKeychainStatus()
        try XCTSkipIf(SecKeychainCopyDefault(&keychain) != errSecSuccess || keychain == nil,
                      "login keychain is unavailable")
        try XCTSkipIf(SecKeychainGetStatus(keychain!, &status) != errSecSuccess ||
                      status & SecKeychainStatus(kSecUnlockStateStatus) == 0,
                      "login keychain must be unlocked for credential integration testing")
        let relay = HttpServer()
        let lock = NSLock()
        var registrations = 0
        relay["/api/v1/register"] = { request in
            let message = try? JSONDecoder().decode(RemoteWireMessage.self, from: Data(request.body))
            XCTAssertEqual(message?.enrollmentKey, "")
            lock.withLock { registrations += 1 }
            return .ok(.text("{\"device_id\":\"test\",\"device_token\":\"test-token\"}"))
        }
        relay["/api/v1/enroll"] = { _ in
            XCTFail("a blank key must use automatic registration")
            return .unauthorized
        }
        relay["/api/v1/agent"] = websocket(text: { socket, raw in
            if (try? JSONDecoder().decode(RemoteWireMessage.self, from: Data(raw.utf8)))?.type == "share.start" {
                socket.writeText("{\"type\":\"share.ready\",\"share_url\":\"http://127.0.0.1/share/test/\"}")
            }
        }, connected: { $0.writeText("{\"type\":\"hello\",\"protocol\":2}") })
        try relay.start(0, forceIPv4: true)
        defer { relay.stop() }
        let base = URL(string: "http://127.0.0.1:\(try relay.port())")!
        try XCTSkipIf(try RemoteKeychain.value(for: RemoteKeychain.deviceAccount(for: base)) != nil,
                      "test address already has credentials")
        let preferences = Preferences()
        defer { preferences.restore() }
        let state = AppState()
        defer {
            state.stop()
            state.forgetRemoteDevice()
        }
        state.saveRemoteSettings(RemoteSettings(serverAddress: base.absoluteString))
        state.setSharedText("test")
        _ = try await request(state, path: "/ls/text")
        state.connectRemote(enrollmentKey: " \n")
        _ = try await publishedURL(state)
        XCTAssertEqual(lock.withLock { registrations }, 1)
        XCTAssertTrue(state.remotePaired)

        state.selectedInterface = NetworkInterface(name: "en0", ip: "192.168.1.2")
        let local = try XCTUnwrap(state.shareAddresses.first { $0.kind == .localIP })
        XCTAssertEqual(state.primaryURL, local.qrURL, "connecting must preserve the current QR entry")
        state.selectShareAddress(.publicRelay)
        XCTAssertEqual(state.primaryURL, state.remoteURL)
        state.disconnectRemote()
        XCTAssertEqual(state.selectedAddressKind, .localIP)
        XCTAssertEqual(state.primaryURL, local.qrURL)
        state.connectRemote(enrollmentKey: "")
        _ = try await publishedURL(state)
        XCTAssertEqual(state.primaryURL, local.qrURL, "reconnecting must not switch the QR back to the internet")
        XCTAssertEqual(lock.withLock { registrations }, 1)

        state.forgetRemoteDevice()
        let error = await state.pairRemote(enrollmentKey: " ")
        XCTAssertNil(error)
        XCTAssertTrue(state.remotePaired)
        XCTAssertEqual(lock.withLock { registrations }, 2)
    }

    @MainActor func testCustomServerRequiresKeyWhenAutomaticRegistrationIsClosed() async throws {
        let relay = HttpServer()
        relay["/api/v1/register"] = { _ in .notFound }
        relay["/api/v1/enroll"] = { _ in
            XCTFail("a blank key must use automatic registration")
            return .unauthorized
        }
        try relay.start(0, forceIPv4: true)
        defer { relay.stop() }
        let preferences = Preferences()
        defer { preferences.restore() }
        let state = AppState()
        defer { state.stop() }
        state.saveRemoteSettings(RemoteSettings(serverAddress: "http://127.0.0.1:\(try relay.port())"))
        let error = await state.pairRemote(enrollmentKey: "")
        XCTAssertEqual(error, L.remoteRegistrationClosed(state.lang))
        XCTAssertFalse(state.remotePaired)
    }

    @MainActor func testColdLaunchRestoresDraftWithoutPublishing() async throws {
        let preferences = Preferences()
        defer { preferences.restore() }
        UserDefaults.standard.set(true, forKey: "persistSharedText")
        UserDefaults.standard.set("saved draft", forKey: "lastSharedText")
        UserDefaults.standard.set([RemoteSettings.defaultServerAddress], forKey: "remotePairedServerAddresses")

        let state = AppState()
        defer { state.stop() }
        XCTAssertTrue(state.remoteSettings.usesDefaultService)
        XCTAssertTrue(state.remotePaired)
        XCTAssertEqual(state.textDraft, "saved draft")
        XCTAssertTrue(state.sharedItems.isEmpty)
        XCTAssertNil(state.sharedText)
        XCTAssertFalse(state.isRunning)
        XCTAssertFalse(state.remoteAccessEnabled)
        XCTAssertFalse(state.remoteTextInboxEnabled)
        XCTAssertNil(state.primaryURL)
        XCTAssertNil(state.remoteURL)

        state.setSharedText(state.textDraft)
        XCTAssertTrue(state.isRunning)
        XCTAssertTrue(state.isTextOnly)
        XCTAssertFalse(state.remoteAccessEnabled)
        let response = try await request(state, path: "/ls/text")
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(String(decoding: response.body, as: UTF8.self), "saved draft")
    }

    @MainActor func testRemoteConnectionKeepsLANPermissions() async throws {
        let relay = HttpServer()
        relay["/api/v1/enroll"] = { _ in
            Thread.sleep(forTimeInterval: 0.4)
            return .unauthorized
        }
        try relay.start(0, forceIPv4: true)
        defer { relay.stop() }
        let preferences = Preferences()
        defer { preferences.restore() }
        UserDefaults.standard.set("http://127.0.0.1:\(try relay.port())", forKey: "remoteServerAddress")
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let state = AppState()
        defer { state.stop() }
        state.setShared(root)
        state.setUploadAllowed(true)
        state.setTextInboxEnabled(true)
        state.setSharedText("shared text")
        // Let the initial network-monitor event run before connecting.
        let beforeConnection = try await request(state, path: "/a.txt")
        XCTAssertEqual(beforeConnection.status, 200)
        let failure = expectation(description: "enrollment rejected")
        let subscription = state.$remoteError.compactMap { $0 }.first().sink { _ in failure.fulfill() }
        defer { subscription.cancel() }

        state.connectRemote(enrollmentKey: "invalid")
        XCTAssertTrue(state.remoteAccessEnabled)
        assertLANPermissions(state)
        let upload = "--test\r\nContent-Disposition: form-data; name=\"file\"; filename=\"uploaded.txt\"\r\nContent-Type: text/plain\r\n\r\nfrom LAN\r\n--test--\r\n"
        let uploaded = try await request(state, path: "/", method: "POST", body: upload,
                                         contentType: "multipart/form-data; boundary=test")
        XCTAssertEqual(uploaded.status, 200)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("uploaded.txt")), "from LAN")
        let received = try await request(state, path: "/ls/text", method: "POST", body: "LAN text")
        XCTAssertEqual(received.status, 200)
        await fulfillment(of: [failure], timeout: 3)
        XCTAssertFalse(state.remoteAccessEnabled)
        assertLANPermissions(state)
        XCTAssertTrue(state.receivedTexts.contains { $0.text == "LAN text" })

        state.connectRemote(enrollmentKey: "invalid")
        state.disconnectRemote()
        XCTAssertFalse(state.remoteAccessEnabled)
        assertLANPermissions(state)
        let afterDisconnect = try await request(state, path: "/a.txt")
        XCTAssertEqual(afterDisconnect.status, 200)
    }

    @MainActor func testShareReplacementClearAndStopRotateAccess() async throws {
        let preferences = Preferences()
        defer { preferences.restore() }
        let oldRoot = try makeRoot(), newRoot = try makeRoot()
        defer {
            try? FileManager.default.removeItem(at: oldRoot)
            try? FileManager.default.removeItem(at: newRoot)
        }
        try Data("new".utf8).write(to: newRoot.appendingPathComponent("a.txt"))
        let state = AppState()
        defer { state.stop() }
        state.setShared(oldRoot)
        let oldToken = state.token, initialPort = state.port
        state.setSharedText("first text")
        state.setSharedText("updated text")
        XCTAssertEqual(state.token, oldToken)
        XCTAssertEqual(state.port, initialPort)

        state.setShared(newRoot)
        XCTAssertNotEqual(state.token, oldToken)
        XCTAssertEqual(state.port, initialPort)
        let previous = try await request(state, path: "/a.txt", token: oldToken)
        XCTAssertEqual(previous.status, 403)
        let current = try await request(state, path: "/a.txt")
        XCTAssertEqual(String(decoding: current.body, as: UTF8.self), "new")

        let beforeClear = state.token
        state.clearShare()
        XCTAssertFalse(state.isRunning)
        XCTAssertTrue(state.sharedItems.isEmpty)
        XCTAssertNil(state.sharedText)
        XCTAssertNil(state.remoteURL)
        XCTAssertNotEqual(state.token, beforeClear)
        state.setShared(newRoot)
        let cleared = try await request(state, path: "/a.txt", token: beforeClear)
        XCTAssertEqual(cleared.status, 403)

        state.setTextInboxEnabled(true)
        let beforeInboxClear = state.token
        state.clearShare()
        XCTAssertTrue(state.isRunning)
        XCTAssertTrue(state.isReceiveOnly)
        XCTAssertNotEqual(state.token, beforeInboxClear)
        let inboxPrevious = try await request(state, path: "/a.txt", token: beforeInboxClear)
        XCTAssertEqual(inboxPrevious.status, 403)
        let removed = try await request(state, path: "/a.txt")
        XCTAssertEqual(removed.status, 404)
        let beforeStop = state.token
        state.stop()
        XCTAssertFalse(state.isRunning)
        XCTAssertNil(state.remoteURL)
        XCTAssertNotEqual(state.token, beforeStop)
    }

    @MainActor func testPublishedShareFollowsAppStateSessionBoundaries() async throws {
        var keychain: SecKeychain?
        var status = SecKeychainStatus()
        try XCTSkipIf(SecKeychainCopyDefault(&keychain) != errSecSuccess || keychain == nil,
                      "login keychain is unavailable")
        try XCTSkipIf(SecKeychainGetStatus(keychain!, &status) != errSecSuccess ||
                      status & SecKeychainStatus(kSecUnlockStateStatus) == 0,
                      "login keychain must be unlocked for credential integration testing")
        let relay = HttpServer()
        let messages = Publications()
        relay["/api/v1/enroll"] = { _ in
            .ok(.text("{\"device_id\":\"test\",\"device_token\":\"test-token\"}"))
        }
        relay["/api/v1/agent"] = websocket(text: { socket, raw in
            guard let message = try? JSONDecoder().decode(RemoteWireMessage.self, from: Data(raw.utf8)),
                  message.type == "share.start" else { return }
            let count = messages.append(message.shareID ?? "")
            socket.writeText("{\"type\":\"share.ready\",\"share_url\":\"http://127.0.0.1/share/\(count)/\"}")
        }, connected: { $0.writeText("{\"type\":\"hello\",\"protocol\":2}") })
        try relay.start(0, forceIPv4: true)
        defer { relay.stop() }
        let serverURL = URL(string: "http://127.0.0.1:\(try relay.port())")!
        let account = RemoteKeychain.deviceAccount(for: serverURL)
        try XCTSkipIf(try RemoteKeychain.value(for: account) != nil, "test address already has credentials")
        let preferences = Preferences()
        defer { preferences.restore() }
        UserDefaults.standard.set(serverURL.absoluteString, forKey: "remoteServerAddress")
        let oldRoot = try makeRoot(), newRoot = try makeRoot()
        defer {
            try? FileManager.default.removeItem(at: oldRoot)
            try? FileManager.default.removeItem(at: newRoot)
        }
        let state = AppState()
        defer {
            state.stop()
            state.forgetRemoteDevice()
        }
        state.setShared(oldRoot)
        _ = try await request(state, path: "/a.txt")
        state.connectRemote(enrollmentKey: "test-key")
        let first = try await publishedURL(state)
        XCTAssertEqual(messages.last, state.token)
        state.selectedInterface = NetworkInterface(name: "en0", ip: "192.168.1.2")
        XCTAssertTrue(state.shareAddresses.contains { $0.kind == .localIP })
        XCTAssertTrue(state.shareAddresses.contains { $0.kind == .publicRelay && $0.url == first })
        XCTAssertNotEqual(state.primaryURL, first)
        state.selectShareAddress(.publicRelay)
        XCTAssertEqual(state.primaryURL, first)

        let republished = expectation(description: "text edits must keep the published link")
        republished.isInverted = true
        let firstBase = state.remoteShareBaseURL
        let subscription = state.$remoteShareBaseURL.dropFirst().sink {
            if $0 != firstBase { republished.fulfill() }
        }
        state.setSharedText("first text")
        state.setSharedText("updated text")
        await fulfillment(of: [republished], timeout: 0.3)
        subscription.cancel()
        XCTAssertEqual(state.remoteURL, first)

        let oldToken = state.token
        state.setShared(newRoot)
        XCTAssertNil(state.remoteURL)
        let second = try await publishedURL(state, differentFrom: first)
        XCTAssertNotEqual(state.token, oldToken)
        XCTAssertEqual(messages.last, state.token)
        state.setRemoteTextInboxEnabled(true)
        let beforeClear = state.token
        state.clearShare()
        let inbox = try await publishedURL(state, differentFrom: second)
        XCTAssertTrue(inbox.hasSuffix("/ls/text"))
        XCTAssertTrue(state.isReceiveOnly)
        XCTAssertFalse(state.textInboxEnabled)
        XCTAssertNotEqual(state.token, beforeClear)
        XCTAssertEqual(messages.last, state.token)
        let stale = try await request(state, path: "/a.txt", token: beforeClear)
        XCTAssertEqual(stale.status, 403)
        let removed = try await request(state, path: "/a.txt")
        XCTAssertEqual(removed.status, 404)

        state.stop()
        XCTAssertNil(state.remoteURL)
        XCTAssertFalse(state.remoteAccessEnabled)
        let publishedCount = messages.count
        state.setShared(newRoot)
        _ = try await request(state, path: "/a.txt")
        XCTAssertNil(state.remoteURL)
        XCTAssertFalse(state.remoteAccessEnabled)
        XCTAssertEqual(messages.count, publishedCount)
    }

    @MainActor private func publishedURL(_ state: AppState, differentFrom previous: String? = nil) async throws -> String {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if let url = state.remoteURL, url != previous { return url }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("AppState did not publish the expected share")
        return try XCTUnwrap(state.remoteURL)
    }

    private final class Publications {
        private let lock = NSLock()
        private var ids: [String] = []
        var last: String? { lock.lock(); defer { lock.unlock() }; return ids.last }
        var count: Int { lock.lock(); defer { lock.unlock() }; return ids.count }
        func append(_ id: String) -> Int {
            lock.lock(); defer { lock.unlock() }
            ids.append(id)
            return ids.count
        }
    }

    @MainActor private func assertLANPermissions(_ state: AppState, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(state.permission.add, file: file, line: line)
        XCTAssertTrue(state.effectivePermission.add, file: file, line: line)
        XCTAssertTrue(state.textInboxEnabled, file: file, line: line)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: "textInboxEnabled"), file: file, line: line)
        XCTAssertTrue(state.isRunning, file: file, line: line)
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: root.appendingPathComponent("a.txt"))
        return root
    }

    @MainActor private func request(_ state: AppState, path: String, token: String? = nil,
                                    method: String = "GET", body: String? = nil,
                                    contentType: String = "text/plain") async throws -> (status: Int, body: Data) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(state.port)\(path)?t=\(token ?? state.token)")!)
        request.timeoutInterval = 3
        request.httpMethod = method
        request.httpBody = body.map { Data($0.utf8) }
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.data(for: request)
        return ((response as! HTTPURLResponse).statusCode, data)
    }

    @MainActor private final class Preferences {
        private let keys = ["autoStopMinutes", "customAutoStopMinutes", "configuredPort", "remoteServerAddress",
                            "remotePairedServerAddresses", "bindSelectedOnly", "tailscaleAccessEnabled",
                            "textInboxEnabled", "persistSharedText", "lastSharedText", "persistReceivedText",
                            "receivedTexts", "recentShares", "languagePref", "accessCodeEnabled"]
        private var saved: [String: Any] = [:]
        private let lang = Lang.current

        init() {
            for key in keys {
                if let value = UserDefaults.standard.object(forKey: key) { saved[key] = value }
                UserDefaults.standard.removeObject(forKey: key)
            }
            UserDefaults.standard.set(0, forKey: "autoStopMinutes")
            UserDefaults.standard.set(Int.random(in: 30000...50000), forKey: "configuredPort")
            UserDefaults.standard.set("en", forKey: "languagePref")
        }

        func restore() {
            for key in keys {
                if let value = saved[key] { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
            Lang.current = lang
        }
    }
}
