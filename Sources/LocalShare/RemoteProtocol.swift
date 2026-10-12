import Foundation
import Darwin

struct RemoteDisplayError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct RemoteWireMessage: Codable {
    static let version = 2
    var type: String
    var protocolVersion: Int? = nil
    var requestID: String? = nil
    var method: String? = nil
    var path: String? = nil
    var headers: [String: String]? = nil
    var clientIP: String? = nil
    var status: Int? = nil
    var error: String? = nil
    var shareURL: String? = nil
    var shareID: String? = nil
    var deviceName: String? = nil
    var enrollmentKey: String? = nil
    var body: Data? = nil
    var textInbox: Bool? = nil

    enum CodingKeys: String, CodingKey {
        case type
        case protocolVersion = "protocol"
        case requestID = "request_id"
        case method, path, headers, status, error, body
        case clientIP = "client_ip"
        case shareURL = "share_url"
        case shareID = "share_id"
        case deviceName = "device_name"
        case enrollmentKey = "enrollment_key"
        case textInbox = "text_inbox"
    }
}

struct RemoteEnrollmentResponse: Decodable {
    let deviceID: String
    let deviceToken: String

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case deviceToken = "device_token"
    }
}

enum RemoteLocalEvent {
    case headers(Int, [String: String])
    case data(Data)
    case finished(Error?)
}

enum RemoteFrameCodec {
    static func encode(_ id: String, _ data: Data) -> Data {
        let idData = Data(id.utf8)
        var result = Data()
        var length = UInt32(idData.count).bigEndian
        withUnsafeBytes(of: &length) { result.append(contentsOf: $0) }
        result.append(idData)
        result.append(data)
        return result
    }
}

enum RemoteRedirectPolicy {
    static func shouldFollow(_ response: HTTPURLResponse) -> Bool {
        response.statusCode == 302 &&
            (response.value(forHTTPHeaderField: "Set-Cookie") ?? "").contains("ls_token=")
    }
}

enum RemoteShareGate {
    static func accepts(_ shareID: String?, currentToken: String) -> Bool {
        !currentToken.isEmpty && shareID == currentToken
    }
}

enum RemoteRequestPolicy {
    static let clientIPHeader = "X-LocalShare-Client-IP"

    static func isValidClientIP(_ address: String) -> Bool {
        guard !address.utf8.contains(0) else { return false }
        var ipv4 = in_addr(), ipv6 = in6_addr()
        return address.withCString {
            inet_pton(AF_INET, $0, &ipv4) == 1 || inet_pton(AF_INET6, $0, &ipv6) == 1
        }
    }

    static func accepts(method: String, path: String, receivingText: Bool) -> Bool {
        if method == "GET" || method == "HEAD" { return true }
        return receivingText && method == "POST" && path.split(separator: "?", maxSplits: 1).first == "/ls/text"
    }
}
