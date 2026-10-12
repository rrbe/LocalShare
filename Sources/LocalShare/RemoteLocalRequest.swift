import Foundation

final class RemoteLocalRequest: NSObject, @unchecked Sendable, URLSessionDataDelegate, URLSessionTaskDelegate {
    let id: String
    private let request: URLRequest
    private let emit: (RemoteLocalEvent) -> Void
    private var session: URLSession?
    private var task: URLSessionDataTask?

    init(id: String, request: URLRequest, emit: @escaping (RemoteLocalEvent) -> Void) {
        self.id = id
        self.request = request
        self.emit = emit
    }

    func start() {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: queue)
        self.session = session
        let task = session.dataTask(with: request)
        self.task = task
        task.resume()
    }

    func resumeAfterChunk() { task?.resume() }
    func cancel() { task?.cancel(); invalidate() }
    func invalidate() { session?.invalidateAndCancel(); session = nil; task = nil }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(RemoteRedirectPolicy.shouldFollow(response) ? request : nil)
    }

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
        dataTask.suspend()
        emit(.data(data))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        emit(.finished(error))
    }
}
