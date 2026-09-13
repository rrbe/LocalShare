import XCTest
@testable import LocalShare

final class ShareAutoStopTests: XCTestCase {
    @MainActor
    func testExpiresOnceAtDeadline() {
        let timer = ShareAutoStop()
        var expirations = 0
        timer.onExpire = { expirations += 1 }
        let deadline = Date().addingTimeInterval(120)
        timer.schedule(at: deadline)
        timer.checkExpiration(now: deadline.addingTimeInterval(-1))
        XCTAssertEqual(expirations, 0)
        timer.checkExpiration(now: deadline)
        timer.checkExpiration(now: deadline.addingTimeInterval(1))
        XCTAssertEqual(expirations, 1)
        XCTAssertNil(timer.deadline)
    }

    @MainActor
    func testReplacingShareDiscardsOldDeadline() {
        let timer = ShareAutoStop()
        var expired = false
        timer.onExpire = { expired = true }
        let oldDeadline = Date().addingTimeInterval(60)
        let newDeadline = oldDeadline.addingTimeInterval(120)
        timer.schedule(at: oldDeadline)
        timer.schedule(at: newDeadline)
        timer.checkExpiration(now: oldDeadline)
        XCTAssertFalse(expired)
        XCTAssertEqual(timer.deadline, newDeadline)
        timer.checkExpiration(now: newDeadline)
        XCTAssertTrue(expired)
    }

    @MainActor
    func testStopAndNeverCancelPendingExpiration() {
        let timer = ShareAutoStop()
        timer.onExpire = { XCTFail("Cancelled sharing must not expire again") }
        let deadline = Date().addingTimeInterval(60)
        timer.schedule(at: deadline)
        timer.cancel()
        timer.checkExpiration(now: deadline)
        XCTAssertNil(timer.deadline)
        timer.schedule(at: deadline)
        timer.schedule(at: nil)
        timer.checkExpiration(now: deadline)
        XCTAssertNil(timer.deadline)
    }

    @MainActor
    func testWakeAfterDeadlineExpiresImmediately() {
        let timer = ShareAutoStop()
        var expired = false
        timer.onExpire = { expired = true }
        let deadline = Date().addingTimeInterval(60)
        timer.schedule(at: deadline)
        timer.checkExpiration(now: deadline.addingTimeInterval(8 * 3600))
        XCTAssertTrue(expired)
    }

    @MainActor
    func testRunLoopFiresExpiration() async {
        let timer = ShareAutoStop()
        let expired = expectation(description: "Scheduled timer expires")
        timer.onExpire = { expired.fulfill() }
        timer.schedule(at: Date().addingTimeInterval(0.05))
        await fulfillment(of: [expired], timeout: 2)
        XCTAssertNil(timer.deadline)
    }
}
