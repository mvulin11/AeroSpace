@testable import AppBundle
import XCTest

final class RunLoopTimeoutTest: XCTestCase {
    private func startRunLoopThread() -> Thread {
        let thread = Thread {
            // A port source keeps the run loop from exiting while it waits for actions
            RunLoop.current.add(NSMachPort(), forMode: .default)
            RunLoop.current.run()
        }
        thread.name = "RunLoopTimeoutTest"
        thread.start()
        return thread
    }

    func testHealthyCallReturnsBeforeTimeout() async throws {
        let thread = startRunLoopThread()
        let result = try await thread.runInLoop(.cancellable, timeout: .seconds(5)) { _ in 42 }
        assertEquals(result, 42)
    }

    func testWedgedThreadTimesOutAndRecovers() async throws {
        let thread = startRunLoopThread()
        // Wedge the thread the same way a busy app's AX call does: a blocking action
        thread.runInLoopAsync(job: RunLoopJob(.nonCancellable)) { _ in Thread.sleep(forTimeInterval: 1.5) }

        let start = Date()
        do {
            _ = try await thread.runInLoop(.cancellable, timeout: .milliseconds(200)) { _ in 1 }
            XCTFail("expected AxTimeoutError")
        } catch is AxTimeoutError {
            // expected
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0, "timeout must fire while the thread is still wedged")

        // Let the wedge clear and the ABANDONED action run to completion: its late resume
        // must be swallowed by the one-shot claim (a double resume would crash here)
        try await Task.sleep(for: .seconds(1.8))
        let result = try await thread.runInLoop(.cancellable, timeout: .seconds(5)) { _ in 7 }
        assertEquals(result, 7)
    }

    func testNilTimeoutMeansStockBlockingBehavior() async throws {
        let thread = startRunLoopThread()
        thread.runInLoopAsync(job: RunLoopJob(.nonCancellable)) { _ in Thread.sleep(forTimeInterval: 0.4) }
        let start = Date()
        let result = try await thread.runInLoop(.cancellable) { _ in 3 }
        assertEquals(result, 3)
        XCTAssertGreaterThan(Date().timeIntervalSince(start), 0.3, "without a timeout the call must wait out the wedge")
    }
}
