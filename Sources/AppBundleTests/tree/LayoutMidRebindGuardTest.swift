@testable import AppBundle
import Common
import XCTest

@MainActor
final class LayoutMidRebindGuardTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        layoutTilesPostChildHookForTests = nil
    }

    override func tearDown() async throws {
        layoutTilesPostChildHookForTests = nil
    }

    /// Regression for the 2026-07-28 server crash: layoutTiles suspends on AX per child, and
    /// sessions are not mutually exclusive, so a concurrent session that rebinds a
    /// not-yet-laid-out child during the suspension (background-tab shelve, native fullscreen,
    /// GC, count-based reshape) made the next iteration's weight accessor die() against the
    /// loop's stale snapshot — fatal for the whole server. The rebound child must be skipped
    /// and the pass must complete for the remaining children.
    func testChildReboundDuringLayoutPassIsSkippedNotFatal() async throws {
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer
        let win1 = TestWindow.new(id: 1, parent: root)
        let win2 = TestWindow.new(id: 2, parent: root)
        let win3 = TestWindow.new(id: 3, parent: root)

        // Simulate a concurrent session shelving window 2 as a background native tab while
        // window 1's subtree is still being laid out
        layoutTilesPostChildHookForTests = { child in
            if (child as? Window)?.windowId == 1 {
                win2.layoutReason = .macos(prevParentKind: .tilingContainer, restoreToWorkspace: workspace.name)
                win2.bind(to: macosMinimizedWindowsContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
            }
        }

        try await workspace.layoutWorkspace() // die()'d here before the guard

        assertEquals(win1.setAxFrameCallsForTest.isEmpty, false)
        assertEquals(win3.setAxFrameCallsForTest.isEmpty, false)
        assertEquals(win2.setAxFrameCallsForTest.isEmpty, true) // skipped, not laid out
        assertEquals(win2.parent === macosMinimizedWindowsContainer, true) // rebind left intact
        assertEquals(root.children.compactMap { ($0 as? Window)?.windowId }, [1, 3])

        win2.unbindFromParent() // don't leak a shelved window into other tests
    }

    /// Same interleave, other direction: the container's layout can be flipped mid-pass
    /// (e.g. `layout accordion` from another session). setWeight die()s for non-tiles
    /// parents, so the stale pass must bail instead
    func testLayoutFlipDuringLayoutPassBailsNotFatal() async throws {
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer
        let win1 = TestWindow.new(id: 1, parent: root)
        let win2 = TestWindow.new(id: 2, parent: root)

        layoutTilesPostChildHookForTests = { child in
            if (child as? Window)?.windowId == 1 {
                root.layout = .accordion
            }
        }

        try await workspace.layoutWorkspace()

        assertEquals(win1.setAxFrameCallsForTest.isEmpty, false)
        assertEquals(win2.setAxFrameCallsForTest.isEmpty, true) // pass bailed before window 2
    }
}
