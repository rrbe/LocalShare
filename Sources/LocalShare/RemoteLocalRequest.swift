import Foundation

@MainActor
final class RemoteLocalRequest: NSObject, URLSessionTaskDelegate {
    let id: String
    private let request: URLRequest
    private let emit: @MainActor (RemoteLocalEvent) async throws -> Void
    private var session: URLSession?
    private var transfer: Task<Void, Never>?

    init(id: String, request: URLRequest, emit: @escaping @MainActor (RemoteLocalEvent) async throws -> Void) {
        self.id = id
        self.request = request
        self.emit = emit
    }

    func start() {
        let session = URLSession(configuration: .ephemeral)
        self.session = session
        let request = self.request
        let emit = self.emit
        transfer = Task.detached { [weak self] in
            do {
                let (bytes, response) = try await session.bytes(for: request, delegate: self)
                guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                var headers: [String: String] = [:]
                for (key, value) in response.allHeaderFields {
                    if let key = key as? String, let value = value as? String { headers[key] = value }
                }
                try await emit(.headers(response.statusCode, headers))
                var chunk = Data()
                chunk.reserveCapacity(65536)
                for try await byte in bytes {
                    chunk.append(byte)
                    if chunk.count == 65536 {
                        try Task.checkCancellation()
                        try await emit(.data(chunk))
                        chunk.removeAll(keepingCapacity: true)
                    }
                }
                if !chunk.isEmpty { try await emit(.data(chunk)) }
                try Task.checkCancellation()
                try await emit(.finished(nil))
            } catch {
                try? await emit(.finished(error))
            }
            session.finishTasksAndInvalidate()
            await self?.finish()

        }
    }

    private func finish() {
        transfer = nil
        session = nil
    }

    func cancel() {
        transfer?.cancel()
        session?.invalidateAndCancel()
    }

    func invalidate() { session?.finishTasksAndInvalidate() }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                                willPerformHTTPRedirection response: HTTPURLResponse,
                                newRequest request: URLRequest,
                                completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(RemoteRedirectPolicy.shouldFollow(response) ? request : nil)
    }
}
