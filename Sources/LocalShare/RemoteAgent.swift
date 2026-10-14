import Foundation

@MainActor
final class RemoteAgent: NSObject {
    private static let pairedServerKey = "remotePairedServerAddresses"

    enum Status: Equatable {
        case disconnected
        case connecting
        case connected
        case reconnecting
    }

    private var serverURL: URL?
    private var localBaseURL: URL?
    private var localToken = ""
    private var localRelayToken = ""
    private var receivingText = false
    private var cachedDeviceToken: String?
    private var cachedCredentialServer: String?
    private var shouldConnect = false
    private var connectionID = UUID()
    private var connectionTask: Task<Void, Never>?
    private var retryDelay: TimeInterval = 1
    private var retryTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var webSocket: URLSessionWebSocketTask?
    private var session: URLSession?
    private var localRequests: [String: RemoteLocalRequest] = [:]
    private var acknowledgments: [String: CheckedContinuation<Void, Error>] = [:]
    private var localRequestLanguages: [String: Lang] = [:]
    private var lang: Lang = .systemDefault
    private let credentialReader: @Sendable (String) throws -> String?

    init(credentialReader: @escaping @Sendable (String) throws -> String? = { try RemoteKeychain.value(for: $0) }) {
        self.credentialReader = credentialReader
        super.init()
    }

    private(set) var status: Status = .disconnected
    private(set) var lastError: String?
    private(set) var shareBaseURL: String?
    var onStateChange: ((Status, String?) -> Void)?
    var onShareURLChange: ((String?) -> Void)?

    var isPaired: Bool {
        isPaired(for: serverURL)
    }

    func isPaired(for serverURL: URL?) -> Bool {
        guard let serverURL else { return false }
        return (UserDefaults.standard.stringArray(forKey: Self.pairedServerKey) ?? []).contains(serverURL.absoluteString)
    }

    func connect(serverURL: URL, enrollmentKey: String, localBaseURL: URL, localToken: String,
                 deviceName: String, lang: Lang, persistCredential: Bool = true,
                 localRelayToken: String = "", receivingText: Bool = false, automaticRegistration: Bool = false) {
        connectionTask?.cancel()
        connectionID = UUID()
        let attempt = connectionID
        shouldConnect = true
        self.lang = lang
        self.serverURL = serverURL
        self.localBaseURL = localBaseURL
        self.localToken = localToken
        self.localRelayToken = localRelayToken
        self.receivingText = receivingText
        retryTask?.cancel()
        retryTask = nil
        closeSocket()
        setStatus(.connecting, error: nil)

        connectionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                if !enrollmentKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    try await self.pair(serverURL: serverURL, enrollmentKey: enrollmentKey,
                                        deviceName: deviceName, lang: lang,
                                        persistCredential: persistCredential)
                }
                if automaticRegistration, try await cachedDeviceToken(for: serverURL) == nil {
                    try await self.pair(serverURL: serverURL, enrollmentKey: "", deviceName: deviceName,
                                        lang: lang, persistCredential: persistCredential, automaticRegistration: true)
                }
                guard try await cachedDeviceToken(for: serverURL) != nil else {
                    throw RemoteDisplayError(message: L.remoteEnrollmentRequired(lang))
                }
                try Task.checkCancellation()
                guard self.shouldConnect, self.connectionID == attempt else { return }
                self.openSocket()
            } catch {
                guard self.connectionID == attempt, !Task.isCancelled else { return }
                self.shouldConnect = false
                self.setStatus(.disconnected, error: Self.displayMessage(for: error, lang: lang))
            }
        }
    }

    func pair(serverURL: URL, enrollmentKey: String, deviceName: String,
              lang: Lang, persistCredential: Bool = true, automaticRegistration: Bool = false) async throws {
        let attempt = connectionID
        let key = enrollmentKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty || automaticRegistration else {
            throw RemoteDisplayError(message: L.remoteEnrollmentRequired(lang))
        }
        let credentials = try await Self.enroll(serverURL: serverURL, key: key,
                                                deviceName: deviceName, lang: lang, automaticRegistration: automaticRegistration)
        try Task.checkCancellation()
        guard connectionID == attempt else { throw CancellationError() }
        if persistCredential {
            do {
                try RemoteKeychain.set(credentials.deviceToken, for: RemoteKeychain.deviceAccount(for: serverURL))
            } catch let failure as RemoteKeychain.Failure {
                throw RemoteDisplayError(message: LStr.remoteKeychainFailed(failure.reason, lang))
            }
        }
        cachedDeviceToken = credentials.deviceToken
        cachedCredentialServer = serverURL.absoluteString
        if persistCredential {
            var addresses = UserDefaults.standard.stringArray(forKey: Self.pairedServerKey) ?? []
            if !addresses.contains(serverURL.absoluteString) { addresses.append(serverURL.absoluteString) }
            UserDefaults.standard.set(addresses, forKey: Self.pairedServerKey)
        }
    }

    func disconnect() {
        connectionID = UUID()
        connectionTask?.cancel()
        connectionTask = nil
        shouldConnect = false
        retryTask?.cancel()
        retryTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        closeSocket()
        shareBaseURL = nil
        onShareURLChange?(nil)
        setStatus(.disconnected, error: nil)
    }

    func forgetDevice(for serverURL: URL?) throws {
        disconnect()
        guard let serverURL else { return }
        try RemoteKeychain.remove(for: RemoteKeychain.deviceAccount(for: serverURL))
        cachedDeviceToken = nil
        cachedCredentialServer = nil
        let addresses = (UserDefaults.standard.stringArray(forKey: Self.pairedServerKey) ?? []).filter { $0 != serverURL.absoluteString }
        UserDefaults.standard.set(addresses, forKey: Self.pairedServerKey)
    }

    func updateLocalShare(baseURL: URL, token: String) {
        let changed = localToken != token
        localBaseURL = baseURL
        localToken = token
        guard status == .connected, changed else { return }
        shareBaseURL = nil
        onShareURLChange?(nil)
        cancelLocalRequests()
        send(RemoteWireMessage(type: "share.start", protocolVersion: RemoteWireMessage.version, shareID: token, deviceName: nil, textInbox: receivingText))
    }

    func updateReceivingText(_ enabled: Bool) {
        receivingText = enabled
        if status == .connected {
            send(RemoteWireMessage(type: "share.update", shareID: localToken, textInbox: enabled))
        }
    }

    private func openSocket() {
        guard shouldConnect, let serverURL,
              cachedCredentialServer == serverURL.absoluteString, let token = cachedDeviceToken,
              let endpoint = agentURL(for: serverURL) else {
            shouldConnect = false
            setStatus(.disconnected, error: L.remoteInvalidCredentials(lang))
            return
        }
        // Let failed attempts return to our retry scheduler instead of waiting inside URLSession.
        let configuration = URLSessionConfiguration.ephemeral
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: OperationQueue())
        var request = URLRequest(url: endpoint)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        self.session = session
        let task = session.webSocketTask(with: request)
        webSocket = task
        task.maximumMessageSize = 128 << 10
        task.resume()
    }

    private func cachedDeviceToken(for serverURL: URL) async throws -> String? {
        let address = serverURL.absoluteString
        if cachedCredentialServer == address, let cachedDeviceToken {
            return cachedDeviceToken
        }
        let attempt = connectionID
        let reader = credentialReader
        let account = RemoteKeychain.deviceAccount(for: serverURL)
        let stored: String?
        do {
            stored = try await Task.detached { try reader(account) }.value
        } catch let failure as RemoteKeychain.Failure {
            throw RemoteDisplayError(message: LStr.remoteKeychainFailed(failure.reason, lang))
        }
        try Task.checkCancellation()
        guard connectionID == attempt else { throw CancellationError() }
        guard let token = stored, !token.isEmpty else { return nil }
        cachedDeviceToken = token
        cachedCredentialServer = address
        return token
    }

    private func agentURL(for base: URL) -> URL? {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = components.scheme?.lowercased() == "https" ? "wss" : "ws"
        components.path = "/api/v1/agent"
        components.query = nil
        components.fragment = nil
        return components.url
    }

    private func receiveNext(from task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, self.webSocket === task else { return }
                switch result {
                case .success(let message): self.handle(message)
                case .failure(let error): self.connectionEnded(error)
                }
                if self.webSocket === task { self.receiveNext(from: task) }
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .string(let raw):
            guard let data = raw.data(using: .utf8),
                  let message = try? JSONDecoder().decode(RemoteWireMessage.self, from: data) else { return }
            handle(message)
        case .data:
            // File data flows from the Mac to the relay; text request bodies use JSON.
            break
        @unknown default:
            break
        }
    }

    private func handle(_ message: RemoteWireMessage) {
        switch message.type {
        case "hello":
            guard message.protocolVersion == RemoteWireMessage.version else {
                shouldConnect = false
                connectionEnded(RemoteDisplayError(message: L.remoteProtocolMismatch(lang)))
                return
            }
            if let url = shareBaseURL { onShareURLChange?(url) }
        case "share.ready":
            shareBaseURL = message.shareURL
            onShareURLChange?(message.shareURL)
        case "request.begin":
            guard let id = message.requestID, let method = message.method, let path = message.path else { return }
            startLocalRequest(id: id, shareID: message.shareID, method: method,
                              path: path, headers: message.headers ?? [:], body: message.body,
                              clientIP: message.clientIP)
        case "request.cancel":
            if let id = message.requestID { cancelLocalRequest(id) }
        case "response.ack":
            if let id = message.requestID { acknowledgments.removeValue(forKey: id)?.resume() }
        case "error":
            lastError = L.remoteServerError(lang)
            onStateChange?(status, lastError)
        default:
            break
        }
    }

    private func startLocalRequest(id: String, shareID: String?, method: String,
                                   path: String, headers: [String: String], body: Data?, clientIP: String?) {
        guard RemoteShareGate.accepts(shareID, currentToken: localToken) else {
            send(RemoteWireMessage(type: "response.begin", requestID: id,
                                   headers: ["Content-Length": "0"], status: 410))
            send(RemoteWireMessage(type: "response.end", requestID: id))
            return
        }
        guard RemoteRequestPolicy.accepts(method: method, path: path, receivingText: receivingText),
              (body?.count ?? 0) <= FileServer.textInboxLimit else {
            send(RemoteWireMessage(type: "response.begin", requestID: id,
                                   headers: ["Content-Length": "0", "Allow": "GET, HEAD"], status: 405))
            send(RemoteWireMessage(type: "response.end", requestID: id))
            return
        }
        guard let clientIP, RemoteRequestPolicy.isValidClientIP(clientIP) else {
            send(RemoteWireMessage(type: "response.begin", requestID: id,
                                   headers: ["Content-Length": "0"], status: 400))
            send(RemoteWireMessage(type: "response.end", requestID: id))
            return
        }
        let requestLang = Lang.fromAcceptLanguage(headers["Accept-Language"])
        guard let base = localBaseURL, !localToken.isEmpty else {
            send(RemoteWireMessage(type: "error", requestID: id, error: L.remoteLocalUnavailable(requestLang)))
            return
        }
        let separator = path.contains("?") ? "&" : "?"
        guard path.hasPrefix("/"),
              let url = URL(string: base.absoluteString + path + separator + "t=" + localToken) else {
            send(RemoteWireMessage(type: "error", requestID: id, error: L.remoteInvalidRequest(requestLang)))
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue(localRelayToken, forHTTPHeaderField: "X-LocalShare-Relay")
        request.setValue(clientIP, forHTTPHeaderField: RemoteRequestPolicy.clientIPHeader)
        for (key, value) in headers where ["Accept", "Accept-Language", "If-Modified-Since", "If-None-Match", "Range", "User-Agent", "Content-Type"].contains(key) {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let local = RemoteLocalRequest(id: id, request: request) { [weak self] event in
            guard let self else { throw CancellationError() }
            try await self.handleLocalEvent(id: id, event: event)
        }
        localRequests[id] = local
        localRequestLanguages[id] = requestLang
        local.start()
    }

    private func handleLocalEvent(id: String, event: RemoteLocalEvent) async throws {
        guard localRequests[id] != nil else { throw CancellationError() }
        switch event {
        case .headers(let status, let headers):
            send(RemoteWireMessage(type: "response.begin", requestID: id, headers: headers, status: status))
        case .data(let data):
            try await sendDataResponse(id, data: data)
        case .finished(let error):
            if let error, (error as NSError).code != NSURLErrorCancelled {
                let requestLang = localRequestLanguages[id] ?? lang
                send(RemoteWireMessage(type: "error", requestID: id,
                                       error: LStr.remoteRequestFailed(error.localizedDescription, requestLang)))
            } else {
                send(RemoteWireMessage(type: "response.end", requestID: id))
            }
            localRequests.removeValue(forKey: id)?.invalidate()
            localRequestLanguages.removeValue(forKey: id)
        }
    }

    private func sendDataResponse(_ requestID: String, data: Data) async throws {
        guard let webSocket else { throw CancellationError() }
        try await withCheckedThrowingContinuation { continuation in
            acknowledgments[requestID] = continuation
            webSocket.send(.data(Self.encodeData(requestID, data))) { [weak self] error in
                if let error {
                    Task { @MainActor [weak self] in self?.connectionEnded(error, from: webSocket) }
                }
            }
        }
    }

    private func send(_ message: RemoteWireMessage) {
        guard let webSocket, let data = try? JSONEncoder().encode(message), let raw = String(data: data, encoding: .utf8) else { return }
        webSocket.send(.string(raw)) { [weak self] error in
            if let error {
                Task { @MainActor [weak self] in self?.connectionEnded(error, from: webSocket) }
            }
        }
    }

    private func cancelLocalRequest(_ id: String) {
        acknowledgments.removeValue(forKey: id)?.resume(throwing: CancellationError())
        localRequests.removeValue(forKey: id)?.cancel()
        localRequestLanguages.removeValue(forKey: id)
    }

    private func cancelLocalRequests() {
        for continuation in acknowledgments.values { continuation.resume(throwing: CancellationError()) }
        acknowledgments.removeAll()
        for request in localRequests.values { request.cancel() }
        localRequests.removeAll()
        localRequestLanguages.removeAll()
    }

    private func connectionEnded(_ error: Error, from task: URLSessionWebSocketTask? = nil) {
        if let task, webSocket !== task { return }
        guard webSocket != nil else { return }
        closeSocket()
        shareBaseURL = nil
        onShareURLChange?(nil)
        let message = Self.displayMessage(for: error, lang: lang)
        lastError = message
        guard shouldConnect else {
            setStatus(.disconnected, error: message)
            return
        }
        setStatus(.reconnecting, error: message)
        scheduleRetry()
    }

    private func scheduleRetry() {
        guard shouldConnect, retryTask == nil else { return }
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, 60)
        retryTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) } catch { return }
            guard let self, self.shouldConnect else { return }
            self.retryTask = nil
            self.openSocket()
        }
    }

    private func closeSocket() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        cancelLocalRequests()
        webSocket?.cancel(with: .normalClosure, reason: nil)
        webSocket = nil
        session?.invalidateAndCancel()
        session = nil
    }

    private func setStatus(_ value: Status, error: String?) {
        status = value
        lastError = error
        onStateChange?(value, error)
    }

    static func displayMessage(for error: Error, lang: Lang) -> String {
        let failure = error as NSError
        if failure.domain == NSPOSIXErrorDomain { return L.remoteConnectionFailed(lang) }
        guard failure.domain == NSURLErrorDomain else { return error.localizedDescription }
        switch URLError.Code(rawValue: failure.code) {
        case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
             .clientCertificateRejected, .clientCertificateRequired:
            return L.remoteTLSFailed(lang)
        default:
            return L.remoteConnectionFailed(lang)
        }
    }

    private static func enroll(serverURL: URL, key: String, deviceName: String,
                               lang: Lang, automaticRegistration: Bool) async throws -> RemoteEnrollmentResponse {
        let endpoint = serverURL.appendingPathComponent(automaticRegistration ? "api/v1/register" : "api/v1/enroll")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            RemoteWireMessage(type: "enroll", deviceName: deviceName, enrollmentKey: key)
        )
        let session = URLSession(configuration: .ephemeral, delegate: RemoteEnrollmentDelegate(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        if automaticRegistration, (response as? HTTPURLResponse)?.statusCode == 404 {
            throw RemoteDisplayError(message: L.remoteRegistrationClosed(lang))
        }
        if let code = (response as? HTTPURLResponse)?.statusCode, [429, 503].contains(code) {
            throw RemoteDisplayError(message: L.remoteLimitReached(lang))
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw RemoteDisplayError(message: L.remoteEnrollmentRejected(lang))
        }
        return try JSONDecoder().decode(RemoteEnrollmentResponse.self, from: data)
    }

    static func encodeData(_ id: String, _ data: Data) -> Data {
        RemoteFrameCodec.encode(id, data)
    }
}

extension RemoteAgent: URLSessionWebSocketDelegate {
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                                willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                                completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }

    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                                didOpenWithProtocol protocol: String?) {
        Task { @MainActor [weak self] in
            guard let self, self.shouldConnect, self.webSocket === webSocketTask else { return }
            self.retryDelay = 1
            self.setStatus(.connected, error: nil)
            self.send(RemoteWireMessage(type: "hello", protocolVersion: RemoteWireMessage.version,
                                        deviceName: Host.current().localizedName ?? "Mac"))
            if self.localBaseURL != nil {
                self.send(RemoteWireMessage(type: "share.start", protocolVersion: RemoteWireMessage.version,
                                            shareID: self.localToken, textInbox: self.receivingText))
            }
            self.heartbeatTask?.cancel()
            self.heartbeatTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: 15_000_000_000) } catch { return }
                    guard let self, self.webSocket === webSocketTask else { return }
                    webSocketTask.sendPing { [weak self] error in
                        if let error {
                            Task { @MainActor [weak self] in self?.connectionEnded(error, from: webSocketTask) }
                        }
                    }
                }
            }
            self.receiveNext(from: webSocketTask)
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                                didCompleteWithError error: Error?) {
        guard let error, let webSocketTask = task as? URLSessionWebSocketTask else { return }
        let rejected = (task.response as? HTTPURLResponse)?.statusCode == 401
        Task { @MainActor [weak self] in
            guard let self, self.webSocket === webSocketTask else { return }
            if rejected { self.shouldConnect = false }
            self.connectionEnded(rejected ? RemoteDisplayError(message: L.remoteInvalidCredentials(self.lang)) : error, from: webSocketTask)
        }
    }
}

private final class RemoteEnrollmentDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
