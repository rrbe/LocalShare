import XCTest
import Swifter
@testable import LocalShare

final class ShareRotationTests: XCTestCase {
    func testInFlightRequestsStayWithinAuthenticatedShare() throws {
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
            let request = HttpRequest()
            request.method = upload ? "POST" : "GET"
            request.path = upload ? "/" : "/old.txt"
            request.queryParams = [("t", "old-token")]
            request.address = "127.0.0.1"
            if upload {
                request.headers["content-type"] = "multipart/form-data; boundary=rotation"
                request.body = Array("--rotation\r\nContent-Disposition: form-data; name=\"file\"; filename=\"upload.txt\"\r\nContent-Type: text/plain\r\n\r\nupload\r\n--rotation--\r\n".utf8)
            }
            var rotated = false
            // Rotate after authentication and before content routing, independent of socket timing.
            let response = server.handle(request) {
                XCTAssertEqual(server.activeViewers(), 1)
                server.token = "new-token"
                server.share = upload ? .directory(newRoot) : .file(newFile)
                rotated = true
            }
            XCTAssertTrue(rotated)
            XCTAssertEqual(response.statusCode, 200)
            XCTAssertTrue(response.headers()["Set-Cookie"]?.contains("old-token") == true)
            if upload {
                XCTAssertEqual(try String(contentsOf: oldRoot.appendingPathComponent("upload.txt")), "upload")
                XCTAssertFalse(FileManager.default.fileExists(atPath: newRoot.appendingPathComponent("upload.txt").path))
            } else {
                XCTAssertEqual(try responseText(response), "old")
            }
            request.method = "GET"
            request.path = "/new.txt"
            request.body = []
            request.headers = [:]
            XCTAssertEqual(server.handle(request).statusCode, 403)
            request.queryParams = [("t", "new-token")]
            let accepted = server.handle(request)
            XCTAssertEqual(accepted.statusCode, 200)
            XCTAssertEqual(try responseText(accepted), "new")
        }
    }

    private func responseText(_ response: HttpResponse) throws -> String {
        guard case .raw(_, _, _, let write) = response else {
            XCTFail("expected a raw file response")
            return ""
        }
        let writer = BodyWriter()
        try write?(writer)
        return String(decoding: writer.data, as: UTF8.self)
    }

    private final class BodyWriter: HttpResponseBodyWriter {
        var data = Data()
        func write(_ file: String.File) throws { XCTFail("unexpected file writer") }
        func write(_ bytes: [UInt8]) throws { data.append(contentsOf: bytes) }
        func write(_ bytes: ArraySlice<UInt8>) throws { data.append(contentsOf: bytes) }
        func write(_ bytes: NSData) throws { data.append(bytes as Data) }
        func write(_ bytes: Data) throws { data.append(bytes) }
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
