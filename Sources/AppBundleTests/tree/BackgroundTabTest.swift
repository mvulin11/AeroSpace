@testable import AppBundle
import Common
import XCTest

@MainActor
final class BackgroundTabTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        resetClosedTilingPositionsForTests()
        orderedOutWindowIdsForTests = nil
        // Short-circuit the isHidden check before it reaches macAppUnsafe (TestApp is not a MacApp)
        config.automaticallyUnhideMacosHiddenApps = true
    }

    override func tearDown() async throws {
        orderedOutWindowIdsForTests = nil
        resetClosedTilingPositionsForTests()
    }

    func testOrderedOutWindowIsShelvedAndRestored() async throws {
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer
        TestWindow.new(id: 1, parent: root)
        let tab = TestWindow.new(id: 2, parent: root)
        TestWindow.new(id: 3, parent: root)

        orderedOutWindowIdsForTests = [2]
        try await normalizeLayoutReason()
        assertEquals(tab.parent === macosMinimizedWindowsContainer, true)
        if case .macos = tab.layoutReason {} else { XCTFail("expected .macos layoutReason") }
        assertEquals(root.children.compactMap { ($0 as? Window)?.windowId }, [1, 3])

        // Ordered back in (tab switch back): restored to tiling, reclaiming its old index
        orderedOutWindowIdsForTests = []
        // The restore pass iterates the minimized container against focus.workspace
        _ = workspace.focusWorkspace()
        try await normalizeLayoutReason()
        assertEquals(tab.layoutReason, .standard)
        assertEquals(tab.nodeWorkspace === workspace, true)
        assertEquals(root.children.compactMap { ($0 as? Window)?.windowId }, [1, 2, 3])
    }

    /// Regression: the shelf is the GLOBAL `macosMinimizedWindowsContainer` and the restore pass
    /// runs it against `focus.workspace`, so a tab that macOS ordered back in while another
    /// workspace was focused used to be re-tiled *there*. Live, that walked the Ghostty window
    /// over to whichever workspace you had just switched to
    func testOrderedOutTabReturnsToItsOwnWorkspaceNotTheFocusedOne() async throws {
        let home = Workspace.get(byName: name)
        let elsewhere = Workspace.get(byName: name + "-elsewhere")
        let root = home.rootTilingContainer
        TestWindow.new(id: 1, parent: root)
        let tab = TestWindow.new(id: 2, parent: root)

        orderedOutWindowIdsForTests = [2]
        try await normalizeLayoutReason()
        assertEquals(tab.parent === macosMinimizedWindowsContainer, true)

        // Ordered back in while a DIFFERENT workspace holds focus
        orderedOutWindowIdsForTests = []
        _ = elsewhere.focusWorkspace()
        try await normalizeLayoutReason()

        assertEquals(tab.layoutReason, .standard)
        assertEquals(tab.nodeWorkspace === home, true)
        assertEquals(elsewhere.rootTilingContainer.children.isEmpty, true)
        assertEquals(root.children.compactMap { ($0 as? Window)?.windowId }, [1, 2])
    }

    func testNilOrderedOutInfoTouchesNothing() async throws {
        let workspace = Workspace.get(byName: name)
        let window = TestWindow.new(id: 7, parent: workspace.rootTilingContainer)
        orderedOutWindowIdsForTests = nil
        try await normalizeLayoutReason()
        assertEquals(window.parent === workspace.rootTilingContainer, true)
        assertEquals(window.layoutReason, .standard)
    }

    func testVacatedPositionMemory() {
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer
        TestWindow.new(id: 1, parent: root)
        TestWindow.new(id: 2, parent: root)
        let base = Date(timeIntervalSince1970: 1000)

        // Both windows weigh 1, so a weight of 1 is a half share
        recordClosedTilingPosition(pid: 42, parent: root, index: 1, weight: 1, now: base)

        // Wrong pid -> no match
        assertNil(consumeClosedTilingPosition(pid: 43, workspace: workspace, now: base))
        // Expired -> no match (and the entry is pruned)
        assertNil(consumeClosedTilingPosition(pid: 42, workspace: workspace, now: base.addingTimeInterval(10)))

        recordClosedTilingPosition(pid: 42, parent: root, index: 1, weight: 1, now: base)
        let vacated = consumeClosedTilingPosition(pid: 42, workspace: workspace, now: base.addingTimeInterval(1))
        assertEquals(vacated?.parent === root, true)
        assertEquals(vacated?.index, 1)
        // Half share of siblings weighing 2 across 2 children -> 0.5 * 2 * 3/2. The number is an
        // output of the share and the sibling count, not a stored weight
        assertEquals(vacated?.adaptiveWeight, 1.5)
        // Consumed -> gone
        assertNil(consumeClosedTilingPosition(pid: 42, workspace: workspace, now: base.addingTimeInterval(1)))
    }

    func testVacatedPositionIsWorkspaceScoped() {
        let workspace = Workspace.get(byName: name)
        let other = Workspace.get(byName: name + "-other")
        let base = Date(timeIntervalSince1970: 1000)
        recordClosedTilingPosition(pid: 42, parent: workspace.rootTilingContainer, index: 0, weight: 1, now: base)
        assertNil(consumeClosedTilingPosition(pid: 42, workspace: other, now: base))
        XCTAssertNotNil(consumeClosedTilingPosition(pid: 42, workspace: workspace, now: base))
    }

    /// Regression: close a window and reopen one within the TTL and the replacement used to come
    /// back at a third of the container, then a quarter, then an eighth — halving every cycle
    func testVacatedWeightSurvivesTheSurvivorAbsorbingTheSpace() {
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer
        let survivor = TestWindow.new(id: 1, parent: root, adaptiveWeight: 856)
        let closing = TestWindow.new(id: 2, parent: root, adaptiveWeight: 856)
        let base = Date(timeIntervalSince1970: 1000)

        // Closes while the split is still even: 856 of 1712 is a half share
        recordClosedTilingPosition(pid: 42, parent: root, index: 1, weight: closing.getWeight(root.orientation), now: base)
        closing.unbindFromParent()
        // layoutTiles rewrites weights every pass so they sum to the container's size, so the
        // survivor ends up holding all 1712 — the scale the remembered weight was taken on is gone
        survivor.setWeight(root.orientation, 1712)

        let vacated = consumeClosedTilingPosition(pid: 42, workspace: workspace, now: base.addingTimeInterval(1))
        // Replaying the stored 856 would make the replacement 856 of 2568 — a third, and a
        // quarter next time. Restoring the SHARE gives 1712, i.e. 1712 of 3424: a half again
        assertEquals(vacated?.adaptiveWeight, 1712)
    }

    /// The native-tab case the memory exists for: with siblings left over, the restored window
    /// must land back on its ORIGINAL size once layoutTiles has normalised the weights
    func testVacatedWeightRoundTripsExactlyWithSiblings() {
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer
        let container: CGFloat = 1024 // powers of two so the arithmetic is exact in binary
        let a = TestWindow.new(id: 1, parent: root, adaptiveWeight: 256)
        let b = TestWindow.new(id: 2, parent: root, adaptiveWeight: 512)
        let leaving = TestWindow.new(id: 3, parent: root, adaptiveWeight: 256)
        let base = Date(timeIntervalSince1970: 1000)

        recordClosedTilingPosition(pid: 42, parent: root, index: 2, weight: leaving.getWeight(root.orientation), now: base)
        leaving.unbindFromParent()
        // layoutTiles hands the vacated 256 to the survivors, split evenly (+128 each)
        a.setWeight(root.orientation, 384)
        b.setWeight(root.orientation, 640)

        let restored = consumeClosedTilingPosition(pid: 42, workspace: workspace, now: base.addingTimeInterval(1))?.adaptiveWeight
        assertEquals(restored, 384)

        // Replay what layoutTiles will then do: same delta to every child so the sum is `container`
        let delta = (container - (384 + 640 + restored!)) / 3
        assertEquals(restored! + delta, 256) // exactly the size it had before it left
        assertEquals(384 + delta, 256)
        assertEquals(640 + delta, 512)
    }

    /// A window that was its parent's only child has no meaningful share; fall back to the even split
    func testVacatedSoleChildFallsBackToAutoWeight() {
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer
        let only = TestWindow.new(id: 1, parent: root, adaptiveWeight: 1712)
        let base = Date(timeIntervalSince1970: 1000)

        recordClosedTilingPosition(pid: 42, parent: root, index: 0, weight: only.getWeight(root.orientation), now: base)
        assertEquals(consumeClosedTilingPosition(pid: 42, workspace: workspace, now: base)?.adaptiveWeight, WEIGHT_AUTO)
    }

    func testVacatedIndexIsClampedToCurrentChildren() {
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer
        TestWindow.new(id: 1, parent: root)
        let base = Date(timeIntervalSince1970: 1000)
        recordClosedTilingPosition(pid: 42, parent: root, index: 5, weight: 1, now: base)
        let vacated = consumeClosedTilingPosition(pid: 42, workspace: workspace, now: base)
        assertEquals(vacated?.index, 1)
    }
}
