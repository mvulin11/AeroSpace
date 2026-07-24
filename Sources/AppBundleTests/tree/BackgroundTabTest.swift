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

        recordClosedTilingPosition(pid: 42, parent: root, index: 1, weight: 2, now: base)

        // Wrong pid -> no match
        assertNil(consumeClosedTilingPosition(pid: 43, workspace: workspace, now: base))
        // Expired -> no match (and the entry is pruned)
        assertNil(consumeClosedTilingPosition(pid: 42, workspace: workspace, now: base.addingTimeInterval(10)))

        recordClosedTilingPosition(pid: 42, parent: root, index: 1, weight: 2, now: base)
        let vacated = consumeClosedTilingPosition(pid: 42, workspace: workspace, now: base.addingTimeInterval(1))
        assertEquals(vacated?.parent === root, true)
        assertEquals(vacated?.index, 1)
        assertEquals(vacated?.adaptiveWeight, 2)
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
