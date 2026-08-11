import Foundation
import Security

struct RemoteSettings: Equatable {
    var serverAddress = ""

    var serverURL: URL? {
        let raw = serverAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host != nil, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/" else { return nil }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.path = ""
        return components?.url
    }

    var isValid: Bool { serverURL != nil }
}

enum RemoteKeychain {
    private static let service = "live.ezze.localshare.remote"
    static let deviceToken = "device-token"
    static let deviceID = "device-id"
    static let serverAddress = "server-address"

    static func value(for account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ value: String, for account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let data = Data(value.utf8)
        let attributes: [String: Any] = [kSecValueData as String: data]
        if SecItemUpdate(query as CFDictionary, attributes as CFDictionary) != errSecSuccess {
            var item = query
            item[kSecValueData as String] = data
            _ = SecItemAdd(item as CFDictionary, nil)
        }
    }

    static func removeAll() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        _ = SecItemDelete(query as CFDictionary)
    }
}

@MainActor
final class RemoteAgent: NSObject {
    private static let pairedServerKey = "remotePairedServerAddress"

    enum Status: Equatable {
        case disconnected
        case connecting
        case connected
        case reconnecting
    }

    private struct Message: Codable {
        var type: String
        var protocolVersion: Int? = nil
        var requestID: String? = nil
        var method: String? = nil
        var path: String? = nil
        var headers: [String: String]? = nil
        var status: Int? = nil
        var error: String? = nil
        var shareURL: String? = nil
        var deviceName: String? = nil
        var enrollmentKey: String? = nil

        enum CodingKeys: String, CodingKey {
            case type
            case protocolVersion = "protocol"
            case requestID = "request_id"
            case method, path, headers, status, error
            case shareURL = "share_url"
            case deviceName = "device_name"
            case enrollmentKey = "enrollment_key"
        }
    }

    private struct EnrollmentResponse: Decodable {
        let deviceID: String
        let deviceToken: String

        enum CodingKeys: String, CodingKey {
            case deviceID = "device_id"
            case deviceToken = "device_token"
        }
    }

    private enum LocalEvent {
        case headers(Int, [String: String])
        case data(Data)
        case finished(Error?)
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
    private var localRequests: [String: LocalRequest] = [:]

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

    func connect(serverURL: URL, enrollmentKey: String, localBaseURL: URL, localToken: String, deviceName: String) {
        shouldConnect = true
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
                    let credentials = try await Self.enroll(serverURL: serverURL,
                                                             key: enrollmentKey.trimmingCharacters(in: .whitespacesAndNewlines),
                                                             deviceName: deviceName)
                    RemoteKeychain.set(credentials.deviceToken, for: RemoteKeychain.deviceToken)
                    cachedDeviceToken = credentials.deviceToken
                    cachedCredentialServer = serverURL.absoluteString
                    UserDefaults.standard.set(serverURL.absoluteString, forKey: Self.pairedServerKey)
                }
                guard cachedDeviceToken(for: serverURL) != nil else {
                    throw NSError(domain: "LocalShare.Remote", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "Enter an enrollment key first."])
                }
                self.openSocket()
            } catch {
                self.shouldConnect = false
                self.setStatus(.disconnected, error: error.localizedDescription)
            }
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

    func forgetDevice() {
        disconnect()
        RemoteKeychain.removeAll()
        cachedDeviceToken = nil
        cachedCredentialServer = nil
        UserDefaults.standard.removeObject(forKey: Self.pairedServerKey)
    }

    func updateLocalShare(baseURL: URL, token: String) {
        localBaseURL = baseURL
        localToken = token
        guard status == .connected else { return }
        send(Message(type: "share.start", protocolVersion: 1, deviceName: nil))
    }

    private func openSocket() {
        guard let serverURL,
              let token = cachedDeviceToken(for: serverURL),
              let endpoint = agentURL(for: serverURL) else {
            setStatus(.disconnected, error: "Invalid server address or device credentials.")
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
            guard let data = raw.data(using: .utf8), let message = try? JSONDecoder().decode(Message.self, from: data) else { return }
            handle(message)
        case .data:
            // V1 only streams file bytes from the Mac to the server.
            break
        @unknown default:
            break
        }
    }

    private func handle(_ message: Message) {
        switch message.type {
        case "hello":
            if let url = shareBaseURL { onShareURLChange?(url) }
        case "share.ready":
            shareBaseURL = message.shareURL
            onShareURLChange?(message.shareURL)
        case "request.begin":
            guard let id = message.requestID, let method = message.method, let path = message.path else { return }
            startLocalRequest(id: id, method: method, path: path, headers: message.headers ?? [:])
        case "request.cancel":
            if let id = message.requestID { cancelLocalRequest(id) }
        case "error":
            lastError = message.error
            onStateChange?(status, lastError)
        default:
            break
        }
    }

    private func startLocalRequest(id: String, method: String, path: String, headers: [String: String]) {
        guard let base = localBaseURL, !localToken.isEmpty else {
            send(Message(type: "error", requestID: id, error: "Local share is not running."))
            return
        }
        let separator = path.contains("?") ? "&" : "?"
        guard let url = URL(string: base.absoluteString + path + separator + "t=" + localToken) else {
            send(Message(type: "error", requestID: id, error: "Invalid local request path."))
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        for (key, value) in headers where ["Accept", "Accept-Language", "If-Modified-Since", "If-None-Match", "Range", "User-Agent"].contains(key) {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let local = LocalRequest(id: id, request: request) { [weak self] event in
            Task { @MainActor [weak self] in self?.handleLocalEvent(id: id, event: event) }
        }
        localRequests[id] = local
        local.start()
    }

    private func handleLocalEvent(id: String, event: LocalEvent) {
        guard localRequests[id] != nil else { return }
        switch event {
        case .headers(let status, let headers):
            send(Message(type: "response.begin", requestID: id, headers: headers, status: status))
        case .data(let data):
            sendDataResponse(id, data: data)
        case .finished(let error):
            if let error, (error as NSError).code != NSURLErrorCancelled {
                send(Message(type: "error", requestID: id, error: error.localizedDescription))
            } else {
                send(Message(type: "response.end", requestID: id))
            }
            localRequests.removeValue(forKey: id)?.invalidate()
        }
    }

    private func sendDataResponse(_ requestID: String, data: Data) {
        guard let webSocket else { return }
        webSocket.send(.data(encodeData(requestID, data))) { [weak self] error in
            if let error {
                Task { @MainActor [weak self] in self?.connectionEnded(error, from: webSocket) }
            }
        }
    }

    private func send(_ message: Message) {
        guard let webSocket, let data = try? JSONEncoder().encode(message), let raw = String(data: data, encoding: .utf8) else { return }
        webSocket.send(.string(raw)) { [weak self] error in
            if let error {
                Task { @MainActor [weak self] in self?.connectionEnded(error, from: webSocket) }
            }
        }
    }

    private func cancelLocalRequest(_ id: String) {
        localRequests.removeValue(forKey: id)?.cancel()
    }

    private func cancelLocalRequests() {
        for request in localRequests.values { request.cancel() }
        localRequests.removeAll()
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

    private static func enroll(serverURL: URL, key: String, deviceName: String) async throws -> EnrollmentResponse {
        let endpoint = serverURL.appendingPathComponent("api/v1/enroll")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Message(type: "enroll", deviceName: deviceName, enrollmentKey: key))
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "LocalShare.Remote", code: (response as? HTTPURLResponse)?.statusCode ?? 0,
                          userInfo: [NSLocalizedDescriptionKey: "Enrollment was rejected by the server."])
        }
        return try JSONDecoder().decode(EnrollmentResponse.self, from: data)
    }

    static func encodeData(_ id: String, _ data: Data) -> Data {
        let idData = Data(id.utf8)
        var result = Data()
        var length = UInt32(idData.count).bigEndian
        withUnsafeBytes(of: &length) { result.append(contentsOf: $0) }
        result.append(idData)
        result.append(data)
        return result
    }

    private func encodeData(_ id: String, _ data: Data) -> Data { Self.encodeData(id, data) }

    private final class LocalRequest: NSObject, @unchecked Sendable, URLSessionDataDelegate, URLSessionTaskDelegate {
        let id: String
        private let request: URLRequest
        private let emit: (LocalEvent) -> Void
        private var session: URLSession?
        private var task: URLSessionDataTask?

        init(id: String, request: URLRequest, emit: @escaping (LocalEvent) -> Void) {
            self.id = id
            self.request = request
            self.emit = emit
        }

        func start() {
            let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
            self.session = session
            let task = session.dataTask(with: request)
            self.task = task
            task.resume()
        }

        func cancel() { task?.cancel(); invalidate() }
        func invalidate() { session?.invalidateAndCancel(); session = nil; task = nil }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                        didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            guard let response = response as? HTTPURLResponse else {
                completionHandler(.cancel)
                return
            }
            var headers: [String: String] = [:]
            for (key, value) in response.allHeaderFields {
                if let key = key as? String, let value = value as? String { headers[key] = value }
            }
            emit(.headers(response.statusCode, headers))
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            emit(.data(data))
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            emit(.finished(error))
        }
    }
}

extension RemoteAgent: URLSessionWebSocketDelegate {
    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                                didOpenWithProtocol protocol: String?) {
        Task { @MainActor [weak self] in
            guard let self, self.webSocket === webSocketTask else { return }
            self.retryDelay = 1
            self.setStatus(.connected, error: nil)
            self.send(Message(type: "hello", protocolVersion: 1,
                              deviceName: Host.current().localizedName ?? "Mac"))
            if self.localBaseURL != nil { self.send(Message(type: "share.start", protocolVersion: 1)) }
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
