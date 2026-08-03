@testable import AppBundle
import Common
import XCTest

@MainActor
final class CountBasedLayoutTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        config.enableCountBasedLayouts = true
    }

    func testTwoWindowsFlattenedSideBySide() {
        let workspace = Workspace.get(byName: name).apply {
            $0.rootTilingContainer.apply {
                TestWindow.new(id: 1, parent: $0)
                TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1).apply {
                    TestWindow.new(id: 2, parent: $0)
                }
            }
        }
        workspace.normalizeContainers()
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([.window(1), .window(2)]))
    }

    func testThreeWindowsPrimaryPlusStack() {
        let workspace = Workspace.get(byName: name).apply {
            $0.rootTilingContainer.apply {
                TestWindow.new(id: 1, parent: $0)
                TestWindow.new(id: 2, parent: $0)
                TestWindow.new(id: 3, parent: $0)
            }
        }
        workspace.normalizeContainers()
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([.window(1), .v_tiles([.window(2), .window(3)])]))
    }

    func testThreeWindowsMirroredShapeIsAccepted() {
        let workspace = Workspace.get(byName: name).apply {
            $0.rootTilingContainer.apply {
                TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1).apply {
                    TestWindow.new(id: 1, parent: $0)
                    TestWindow.new(id: 2, parent: $0)
                }
                TestWindow.new(id: 3, parent: $0)
            }
        }
        workspace.normalizeContainers()
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([.v_tiles([.window(1), .window(2)]), .window(3)]))
    }

    func testFourWindowsGrid() {
        let workspace = Workspace.get(byName: name).apply {
            $0.rootTilingContainer.apply {
                TestWindow.new(id: 1, parent: $0)
                TestWindow.new(id: 2, parent: $0)
                TestWindow.new(id: 3, parent: $0)
                TestWindow.new(id: 4, parent: $0)
            }
        }
        workspace.normalizeContainers()
        assertEquals(
            workspace.rootTilingContainer.layoutDescription,
            .h_tiles([.v_tiles([.window(1), .window(2)]), .v_tiles([.window(3), .window(4)])]),
        )
    }

    func testMatchingShapePreservesWeights() {
        var window1: Window!
        let workspace = Workspace.get(byName: name).apply {
            $0.rootTilingContainer.apply {
                window1 = TestWindow.new(id: 1, parent: $0)
                TestWindow.new(id: 2, parent: $0)
            }
        }
        window1.setWeight(workspace.rootTilingContainer.orientation, 3)
        workspace.normalizeContainers()
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([.window(1), .window(2)]))
        assertEquals(window1.getWeight(workspace.rootTilingContainer.orientation), 3)
    }

    func testFloatingWindowsAreNotCounted() {
        let workspace = Workspace.get(byName: name).apply {
            $0.rootTilingContainer.apply {
                TestWindow.new(id: 1, parent: $0)
                TestWindow.new(id: 2, parent: $0)
            }
            TestWindow.new(id: 3, parent: $0.floatingWindowsContainer)
        }
        workspace.normalizeContainers()
        assertEquals(
            workspace.layoutDescription,
            .workspace([.h_tiles([.window(1), .window(2)]), .floatingWindowsContainer([.window(3)])]),
        )
    }

    func testFiveWindowsUntouched() {
        let workspace = Workspace.get(byName: name).apply {
            $0.rootTilingContainer.apply {
                TestWindow.new(id: 1, parent: $0)
                TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1).apply {
                    TestWindow.new(id: 2, parent: $0)
                    TestWindow.new(id: 3, parent: $0)
                    TestWindow.new(id: 4, parent: $0)
                }
                TestWindow.new(id: 5, parent: $0)
            }
        }
        workspace.normalizeContainers()
        assertEquals(
            workspace.rootTilingContainer.layoutDescription,
            .h_tiles([.window(1), .v_tiles([.window(2), .window(3), .window(4)]), .window(5)]),
        )
    }

    func testThreeWindowsVerticalRootSnapsBackToHorizontal() {
        // The transposed 3-shape (half on top, quarters below) must never survive
        // normalization unless the workspace's flip flag is set
        let workspace = Workspace.get(byName: name).apply {
            $0.rootTilingContainer.changeOrientation(.v)
            $0.rootTilingContainer.apply {
                TestWindow.new(id: 1, parent: $0)
                TilingContainer.newHTiles(parent: $0, adaptiveWeight: 1).apply {
                    TestWindow.new(id: 2, parent: $0)
                    TestWindow.new(id: 3, parent: $0)
                }
            }
        }
        workspace.normalizeContainers()
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([.window(1), .v_tiles([.window(2), .window(3)])]))
    }

    func testFlipCountLayoutTogglesVerticalAndKeepsTheHalf() async {
        let workspace = Workspace.get(byName: name).apply {
            $0.rootTilingContainer.apply {
                TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1).apply {
                    TestWindow.new(id: 1, parent: $0)
                    TestWindow.new(id: 2, parent: $0)
                }
                TestWindow.new(id: 3, parent: $0)
            }
        }
        assertEquals(workspace.focusWorkspace(), true)

        let result = await parseCommand("flip-count-layout").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode.rawValue, 0)
        assertEquals(workspace.countLayoutVertical, true)
        // Window 3 was the half and stays the half, now spanning the top
        assertEquals(workspace.rootTilingContainer.layoutDescription, .v_tiles([.window(3), .h_tiles([.window(1), .window(2)])]))
        // Normalization respects the flag: the vertical shape is stable
        workspace.normalizeContainers()
        assertEquals(workspace.rootTilingContainer.layoutDescription, .v_tiles([.window(3), .h_tiles([.window(1), .window(2)])]))

        _ = await parseCommand("flip-count-layout").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(workspace.countLayoutVertical, false)
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([.window(3), .v_tiles([.window(1), .window(2)])]))
    }

    func testVerticalFlagClearsWhenWorkspaceGrowsPastThree() {
        let workspace = Workspace.get(byName: name).apply {
            $0.countLayoutVertical = true
            $0.rootTilingContainer.changeOrientation(.v)
            $0.rootTilingContainer.apply {
                TestWindow.new(id: 1, parent: $0)
                TilingContainer.newHTiles(parent: $0, adaptiveWeight: 1).apply {
                    TestWindow.new(id: 2, parent: $0)
                    TestWindow.new(id: 3, parent: $0)
                }
            }
        }
        workspace.normalizeContainers()
        assertEquals(workspace.rootTilingContainer.layoutDescription, .v_tiles([.window(1), .h_tiles([.window(2), .window(3)])]))

        TestWindow.new(id: 4, parent: workspace.rootTilingContainer)
        workspace.normalizeContainers()
        assertEquals(workspace.countLayoutVertical, false)
        // 4 windows -> 2x2 grid; the explicit vertical request doesn't outlive the episode
        assertEquals(
            workspace.rootTilingContainer.layoutDescription,
            .v_tiles([.h_tiles([.window(1), .window(2)]), .h_tiles([.window(3), .window(4)])]),
        )
    }

    func testDisabledByDefaultConfigOption() {
        config.enableCountBasedLayouts = false
        let workspace = Workspace.get(byName: name).apply {
            $0.rootTilingContainer.apply {
                TestWindow.new(id: 1, parent: $0)
                TestWindow.new(id: 2, parent: $0)
                TestWindow.new(id: 3, parent: $0)
            }
        }
        workspace.normalizeContainers()
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([.window(1), .window(2), .window(3)]))
    }
}
