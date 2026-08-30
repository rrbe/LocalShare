import Foundation

@MainActor
final class RemoteAgent: NSObject {
    private static let pairedServerKey = "remotePairedServerAddress"

    enum Status: Equatable {
        case disconnected
        case connecting
        case connected
        case reconnecting
    }

    private var serverURL: URL?
    private var localBaseURL: URL?
    private var localToken = ""
    private var cachedDeviceToken: String?
    private var cachedCredentialServer: String?
    private var shouldConnect = false
    private var retryDelay: TimeInterval = 1
    private var retryTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var webSocket: URLSessionWebSocketTask?
    private var session: URLSession?
    private var localRequests: [String: RemoteLocalRequest] = [:]
    private var localRequestLanguages: [String: Lang] = [:]
    private var lang: Lang = .systemDefault

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
        return UserDefaults.standard.string(forKey: Self.pairedServerKey) == serverURL.absoluteString
    }

    func connect(serverURL: URL, enrollmentKey: String, localBaseURL: URL, localToken: String,
                 deviceName: String, lang: Lang, persistCredential: Bool = true) {
        shouldConnect = true
        self.lang = lang
        self.serverURL = serverURL
        self.localBaseURL = localBaseURL
        self.localToken = localToken
        retryTask?.cancel()
        retryTask = nil
        closeSocket()
        setStatus(.connecting, error: nil)

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                if !enrollmentKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    try await self.pair(serverURL: serverURL, enrollmentKey: enrollmentKey,
                                        deviceName: deviceName, lang: lang,
                                        persistCredential: persistCredential)
                }
                guard cachedDeviceToken(for: serverURL) != nil else {
                    throw RemoteDisplayError(message: L.remoteEnrollmentRequired(lang))
                }
                self.openSocket()
            } catch {
                self.shouldConnect = false
                self.setStatus(.disconnected, error: error.localizedDescription)
            }
        }
    }

    func pair(serverURL: URL, enrollmentKey: String, deviceName: String,
              lang: Lang, persistCredential: Bool = true) async throws {
        let key = enrollmentKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw RemoteDisplayError(message: L.remoteEnrollmentRequired(lang))
        }
        let credentials = try await Self.enroll(serverURL: serverURL, key: key,
                                                deviceName: deviceName, lang: lang)
        if persistCredential {
            do {
                try RemoteKeychain.set(credentials.deviceToken, for: RemoteKeychain.deviceToken)
            } catch let failure as RemoteKeychain.Failure {
                throw RemoteDisplayError(message: LStr.remoteKeychainFailed(failure.reason, lang))
            }
        }
        cachedDeviceToken = credentials.deviceToken
        cachedCredentialServer = serverURL.absoluteString
        if persistCredential {
            UserDefaults.standard.set(serverURL.absoluteString, forKey: Self.pairedServerKey)
        }
    }

    func disconnect() {
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

    func forgetDevice() throws {
        disconnect()
        try RemoteKeychain.removeAll()
        cachedDeviceToken = nil
        cachedCredentialServer = nil
        UserDefaults.standard.removeObject(forKey: Self.pairedServerKey)
    }

    func updateLocalShare(baseURL: URL, token: String) {
        localBaseURL = baseURL
        localToken = token
        guard status == .connected else { return }
        send(RemoteWireMessage(type: "share.start", protocolVersion: 1, shareID: token, deviceName: nil))
    }

    private func openSocket() {
        guard let serverURL,
              let token = cachedDeviceToken(for: serverURL),
              let endpoint = agentURL(for: serverURL) else {
            shouldConnect = false
            setStatus(.disconnected, error: L.remoteInvalidCredentials(lang))
            return
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = true
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: OperationQueue())
        var request = URLRequest(url: endpoint)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        self.session = session
        let task = session.webSocketTask(with: request)
        webSocket = task
        task.resume()
    }

    private func cachedDeviceToken(for serverURL: URL) -> String? {
        let address = serverURL.absoluteString
        if cachedCredentialServer == address, let cachedDeviceToken {
            return cachedDeviceToken
        }
        if UserDefaults.standard.string(forKey: Self.pairedServerKey) != address {
            // Compatibility for credentials created before the paired-server marker existed.
            guard RemoteKeychain.value(for: RemoteKeychain.serverAddress) == address else { return nil }
            UserDefaults.standard.set(address, forKey: Self.pairedServerKey)
        }
        guard let token = RemoteKeychain.value(for: RemoteKeychain.deviceToken), !token.isEmpty else { return nil }
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
            // V1 only streams file bytes from the Mac to the server.
            break
        @unknown default:
            break
        }
    }

    private func handle(_ message: RemoteWireMessage) {
        switch message.type {
        case "hello":
            if let url = shareBaseURL { onShareURLChange?(url) }
        case "share.ready":
            shareBaseURL = message.shareURL
            onShareURLChange?(message.shareURL)
        case "request.begin":
            guard let id = message.requestID, let method = message.method, let path = message.path else { return }
            startLocalRequest(id: id, shareID: message.shareID, method: method,
                              path: path, headers: message.headers ?? [:])
        case "request.cancel":
            if let id = message.requestID { cancelLocalRequest(id) }
        case "error":
            lastError = L.remoteServerError(lang)
            onStateChange?(status, lastError)
        default:
            break
        }
    }

    private func startLocalRequest(id: String, shareID: String?, method: String,
                                   path: String, headers: [String: String]) {
        guard RemoteShareGate.accepts(shareID, currentToken: localToken) else {
            send(RemoteWireMessage(type: "response.begin", requestID: id,
                                   headers: ["Content-Length": "0"], status: 410))
            send(RemoteWireMessage(type: "response.end", requestID: id))
            return
        }
        guard method == "GET" || method == "HEAD" else {
            send(RemoteWireMessage(type: "response.begin", requestID: id,
                                   headers: ["Content-Length": "0", "Allow": "GET, HEAD"], status: 405))
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
        for (key, value) in headers where ["Accept", "Accept-Language", "If-Modified-Since", "If-None-Match", "Range", "User-Agent"].contains(key) {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let local = RemoteLocalRequest(id: id, request: request) { [weak self] event in
            Task { @MainActor [weak self] in self?.handleLocalEvent(id: id, event: event) }
        }
        localRequests[id] = local
        localRequestLanguages[id] = requestLang
        local.start()
    }

    private func handleLocalEvent(id: String, event: RemoteLocalEvent) {
        guard localRequests[id] != nil else { return }
        switch event {
        case .headers(let status, let headers):
            send(RemoteWireMessage(type: "response.begin", requestID: id, headers: headers, status: status))
        case .data(let data):
            sendDataResponse(id, data: data)
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

    private func sendDataResponse(_ requestID: String, data: Data) {
        guard let webSocket else { return }
        webSocket.send(.data(Self.encodeData(requestID, data))) { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let error { self.connectionEnded(error, from: webSocket) }
                else { self.localRequests[requestID]?.resumeAfterChunk() }
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
        localRequests.removeValue(forKey: id)?.cancel()
        localRequestLanguages.removeValue(forKey: id)
    }

    private func cancelLocalRequests() {
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
        let message = error.localizedDescription
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

    private static func enroll(serverURL: URL, key: String, deviceName: String,
                               lang: Lang) async throws -> RemoteEnrollmentResponse {
        let endpoint = serverURL.appendingPathComponent("api/v1/enroll")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            RemoteWireMessage(type: "enroll", deviceName: deviceName, enrollmentKey: key)
        )
        let (data, response) = try await URLSession.shared.data(for: request)
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
    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                                didOpenWithProtocol protocol: String?) {
        Task { @MainActor [weak self] in
            guard let self, self.webSocket === webSocketTask else { return }
            self.retryDelay = 1
            self.setStatus(.connected, error: nil)
            self.send(RemoteWireMessage(type: "hello", protocolVersion: 1,
                                        deviceName: Host.current().localizedName ?? "Mac"))
            if self.localBaseURL != nil {
                self.send(RemoteWireMessage(type: "share.start", protocolVersion: 1,
                                            shareID: self.localToken))
            }
            self.heartbeatTask?.cancel()
            self.heartbeatTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: 15_000_000_000) } catch { return }
                    guard let self, self.webSocket === webSocketTask else { return }
                    webSocketTask.sendPing { error in
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
        Task { @MainActor [weak self] in self?.connectionEnded(error, from: webSocketTask) }
    }
}
