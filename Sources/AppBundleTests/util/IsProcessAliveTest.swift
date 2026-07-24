@testable import AppBundle
import XCTest

final class IsProcessAliveTest: XCTestCase {
    func testOwnProcessIsAlive() {
        XCTAssertTrue(isProcessAlive(getpid()))
    }

    func testInitIsAliveDespiteEperm() {
        // PID 1 (launchd) exists but isn't signalable by us — the EPERM branch
        XCTAssertTrue(isProcessAlive(1))
    }

    func testKilledProcessIsDead() throws {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sleep")
        process.arguments = ["60"]
        try process.run()
        let pid = process.processIdentifier
        XCTAssertTrue(isProcessAlive(pid))
        kill(pid, SIGKILL)
        process.waitUntilExit() // reap so the pid isn't a zombie
        XCTAssertFalse(isProcessAlive(pid))
    }
}
