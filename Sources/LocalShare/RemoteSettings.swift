import Foundation
import Security

struct RemoteSettings: Equatable {
    static let defaultServerAddress = "https://share.fairydog.net"
    var serverAddress = ""

    var usesDefaultService: Bool { serverAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var displayAddress: String { usesDefaultService ? Self.defaultServerAddress : serverAddress }

    var serverURL: URL? {
        let raw = displayAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host != nil, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/" else { return nil }
        if scheme == "http", !Self.isLoopback(url.host ?? "") { return nil }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.path = ""
        return components?.url
    }

    var isValid: Bool { serverURL != nil }

    private static func isLoopback(_ host: String) -> Bool {
        host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]"
    }
}

enum RemoteKeychain {
    private static let service = "live.ezze.localshare.remote"
    static let deviceToken = "device-token"

    static func deviceAccount(for server: URL) -> String { deviceToken + ":" + server.absoluteString }

    struct Failure: Error {
        let status: OSStatus

        var reason: String {
            (SecCopyErrorMessageString(status, nil) as String?) ?? "OSStatus \(status)"
        }
    }

    static func value(for account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw Failure(status: status) }
        guard let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ value: String, for account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let data = Data(value.utf8)
        let attributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw Failure(status: updateStatus) }
        var item = query
        item[kSecValueData as String] = data
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw Failure(status: addStatus) }
    }

    static func remove(for account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure(status: status) }
    }
}
