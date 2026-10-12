import XCTest
import Darwin
import Swifter
@testable import LocalShare

final class ShareRotationTests: XCTestCase {
    func testInFlightRequestsStayWithinAuthenticatedShare() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let oldRoot = root.appendingPathComponent("old"), newRoot = root.appendingPathComponent("new")
        try FileManager.default.createDirectory(at: oldRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: newRoot, withIntermediateDirectories: true)
        let oldFile = oldRoot.appendingPathComponent("old.txt"), newFile = newRoot.appendingPathComponent("new.txt")
        try Data("old".utf8).write(to: oldFile)
        try Data("new".utf8).write(to: newFile)
        for upload in [false, true] {
            let server = FileServer(share: upload ? .directory(oldRoot) : .file(oldFile), token: "old-token")
            server.uploadEnabled = upload
            let port = try server.start(preferredPorts: [in_port_t.random(in: 30000...50000)])
            defer { server.stop() }
            let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
            XCTAssertGreaterThanOrEqual(fd, 0)
            var noSignal: Int32 = 1
            _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            var timeout = timeval(tv_sec: 5, tv_usec: 0)
            _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            _ = "127.0.0.1".withCString { inet_pton(AF_INET, $0, &address.sin_addr) }
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            XCTAssertEqual(connected, 0)
            let socket = Swifter.Socket(socketFileDescriptor: fd)
            defer { socket.close() }
            // Presence is recorded after auth, before this long path is decoded and routed.
            // Single-file reads ignore the filename; repeated encoded slashes upload at the folder root.
            let path = "/" + String(repeating: upload ? "%2f" : "%61", count: 500_000)
            let body = upload ? "--rotation\r\nContent-Disposition: form-data; name=\"file\"; filename=\"upload.txt\"\r\nContent-Type: text/plain\r\n\r\nupload\r\n--rotation--\r\n" : ""
            let headers = upload ? "Content-Type: multipart/form-data; boundary=rotation\r\nContent-Length: \(body.utf8.count)\r\n" : ""
            try socket.writeUTF8("\(upload ? "POST" : "GET") \(path)?t=old-token HTTP/1.1\r\nHost: localhost\r\n\(headers)\r\n\(body)")
            // The intentionally large request line must finish parsing before the rotation.
            let deadline = Date().addingTimeInterval(15)
            while server.activeViewers() == 0 && Date() < deadline {
                try await Task.sleep(nanoseconds: 100_000)
            }
            guard server.activeViewers() == 1 else {
                XCTFail("request did not reach authenticated routing")
                return
            }
            server.token = "new-token"
            server.share = upload ? .directory(newRoot) : .file(newFile)
            let status = try socket.readLine()
            XCTAssertTrue(status.contains("200"))
            while !(try socket.readLine()).isEmpty {}
            if upload {
                XCTAssertEqual(try String(contentsOf: oldRoot.appendingPathComponent("upload.txt")), "upload")
                XCTAssertFalse(FileManager.default.fileExists(atPath: newRoot.appendingPathComponent("upload.txt").path))
            } else {
                XCTAssertEqual(String(decoding: try socket.read(length: 3), as: UTF8.self), "old")
            }
            let base = "http://127.0.0.1:\(port)"
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            let (_, rejected) = try await session.data(from: URL(string: base + "/?t=old-token")!)
            XCTAssertEqual((rejected as? HTTPURLResponse)?.statusCode, 403)
            let (newContent, accepted) = try await session.data(from: URL(string: base + "/new.txt?t=new-token")!)
            XCTAssertEqual((accepted as? HTTPURLResponse)?.statusCode, 200)
            XCTAssertEqual(String(decoding: newContent, as: UTF8.self), "new")
        }
    }

    func testTextBreadcrumbReturnsToMountedShareRoot() {
        let crumbs = DirectoryListing.breadcrumb(requestPath: "/文本", rootName: "Folder", navigationPath: "/ls/text")
        XCTAssertTrue(crumbs.contains("href=\"../\""))
        XCTAssertFalse(crumbs.contains(">ls<"))
        let page = URL(string: "https://share.example.com/share/token/ls/text")!
        XCTAssertEqual(URL(string: "../", relativeTo: page)?.absoluteURL.absoluteString,
                       "https://share.example.com/share/token/")
    }
}
