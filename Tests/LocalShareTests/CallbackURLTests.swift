import XCTest
@testable import LocalShare

final class CallbackURLTests: XCTestCase {
    @MainActor
    func testShareCallbackAcceptsAbsolutePaths() {
        let url = URL(string: "localshare://share?path=/tmp/a.txt&path=/Users/me/docs")!
        let paths = AppDelegate.sharedFileURLs(from: [url]).map(\.path)
        XCTAssertEqual(paths, ["/tmp/a.txt", "/Users/me/docs"])
    }

    @MainActor
    func testShareCallbackRejectsEmptyAndRelativePaths() {
        let url = URL(string: "localshare://share?path=&path=foo&path=../bar&path=/tmp/ok.txt")!
        let paths = AppDelegate.sharedFileURLs(from: [url]).map(\.path)
        XCTAssertEqual(paths, ["/tmp/ok.txt"])
    }
}
