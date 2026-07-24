@testable import AppBundle
import Common
import XCTest

final class PersistedWorkspaceStateTest: XCTestCase {
    private func makeFrozenWorld() -> FrozenWorld {
        let stack = FrozenContainer(
            children: [
                .window(FrozenWindow(id: 2, weight: 1)),
                .window(FrozenWindow(id: 3, weight: 2)),
            ],
            layout: .tiles,
            orientation: .v,
            weight: 1,
        )
        let root = FrozenContainer(
            children: [
                .window(FrozenWindow(id: 1, weight: 1)),
                .container(stack),
            ],
            layout: .accordion,
            orientation: .h,
            weight: 1,
        )
        let monitor = FrozenMonitor(topLeftCorner: CGPoint(x: 0, y: 0), visibleWorkspace: "1")
        let workspace = FrozenWorkspace(
            name: "1",
            monitor: monitor,
            rootTilingNode: root,
            floatingWindows: [FrozenWindow(id: 4, weight: 1)],
            macosUnconventionalWindows: [FrozenWindow(id: 5, weight: 1)],
        )
        return FrozenWorld(workspaces: [workspace], monitors: [monitor], windowIds: [1, 2, 3, 4, 5])
    }

    private func encode(_ world: PersistedWorld) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(world)
    }

    func testJsonRoundTripPreservesWorldAndRecomputesWindowIds() throws {
        let persisted = PersistedWorld(makeFrozenWorld(), bootTime: 1000)
        let data = try encode(persisted)

        let decoded = try JSONDecoder().decode(PersistedWorld.self, from: data)
        assertEquals(decoded.bootTime, 1000)
        let restored = try XCTUnwrap(decoded.toFrozenWorld())
        assertEquals(restored.windowIds, [1, 2, 3, 4, 5])
        assertEquals(restored.workspaces.count, 1)
        assertEquals(restored.monitors.count, 1)

        // Frozen types have no Equatable — byte-compare a second serialization pass instead
        let reencoded = try encode(PersistedWorld(restored, bootTime: 1000))
        assertEquals(reencoded, data)
    }

    func testUnknownLayoutIsRejected() throws {
        let persisted = PersistedWorld(makeFrozenWorld(), bootTime: 1000)
        let json = try String(data: encode(persisted), encoding: .utf8).orDie()
            .replacingOccurrences(of: "\"accordion\"", with: "\"some-future-layout\"")
        let decoded = try JSONDecoder().decode(PersistedWorld.self, from: json.data(using: .utf8).orDie())
        assertNil(decoded.toFrozenWorld())
    }

    func testUnknownOrientationIsRejected() throws {
        let persisted = PersistedWorld(makeFrozenWorld(), bootTime: 1000)
        let json = try String(data: encode(persisted), encoding: .utf8).orDie()
            .replacingOccurrences(of: "\"v\"", with: "\"diagonal\"")
        let decoded = try JSONDecoder().decode(PersistedWorld.self, from: json.data(using: .utf8).orDie())
        assertNil(decoded.toFrozenWorld())
    }
}
