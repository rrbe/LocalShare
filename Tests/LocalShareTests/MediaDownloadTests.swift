import XCTest
@testable import LocalShare

final class MediaDownloadTests: XCTestCase {
    func testByteRanges() {
        XCTAssertEqual(FileServer.byteRange("bytes=0-1", size: 10), 0...1)
        XCTAssertEqual(FileServer.byteRange("bytes=4-", size: 10), 4...9)
        XCTAssertEqual(FileServer.byteRange("bytes=-3", size: 10), 7...9)
        XCTAssertEqual(FileServer.byteRange("bytes=-30", size: 10), 0...9)
        XCTAssertEqual(FileServer.byteRange("bytes=4-99", size: 10), 4...9)
        for invalid in ["bytes=10-", "bytes=5-4", "bytes=-0", "bytes=0-1,4-5", "bytes=a-b", "bytes=0-18446744073709551616"] {
            XCTAssertNil(FileServer.byteRange(invalid, size: 10), invalid)
        }
        XCTAssertNil(FileServer.byteRange("bytes=0-", size: 0))
    }

}
