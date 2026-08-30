import Foundation

struct RemoteDisplayError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct RemoteWireMessage: Codable {
    var type: String
    var protocolVersion: Int? = nil
    var requestID: String? = nil
    var method: String? = nil
    var path: String? = nil
    var headers: [String: String]? = nil
    var status: Int? = nil
    var error: String? = nil
    var shareURL: String? = nil
    var shareID: String? = nil
    var deviceName: String? = nil
    var enrollmentKey: String? = nil

    enum CodingKeys: String, CodingKey {
        case type
        case protocolVersion = "protocol"
        case requestID = "request_id"
        case method, path, headers, status, error
        case shareURL = "share_url"
        case shareID = "share_id"
        case deviceName = "device_name"
        case enrollmentKey = "enrollment_key"
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
