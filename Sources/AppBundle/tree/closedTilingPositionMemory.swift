import AppKit
import Common

// When a native-tab app (Ghostty, Finder, ...) creates or switches tabs, the previously
// active tab's AXWindow leaves the AX list (and gets GC'd) while the newly active tab
// arrives as a "new" window moments later. Without memory the replacement binds via the
// MRU heuristic, so the tab group's tile hops around and the workspace re-sorts.
// Remember recently vacated tiling positions per app for a short window and let the
// replacement window reclaim the exact spot (parent, index, and weight — so the tile
// keeps its size too).

struct ClosedTilingPosition {
    let pid: pid_t
    weak var parent: TilingContainer?
    let index: Int
    let weight: CGFloat
    let closedAt: Date
}

@MainActor private var closedTilingPositions: [ClosedTilingPosition] = []
// Tab transitions complete within one or two refresh sessions; anything older is likely
// an unrelated close and should fall back to the MRU heuristic
private let closedTilingPositionTtl: TimeInterval = 5
private let closedTilingPositionCap = 20

@MainActor func recordClosedTilingPosition(pid: pid_t, parent: TilingContainer, index: Int, weight: CGFloat, now: Date = .now) {
    pruneClosedTilingPositions(now: now)
    closedTilingPositions = Array(closedTilingPositions.suffix(closedTilingPositionCap - 1))
    closedTilingPositions.append(ClosedTilingPosition(pid: pid, parent: parent, index: index, weight: weight, closedAt: now))
}

/// Most recent still-valid position vacated by a window of the same app on the same
/// workspace, removed from the memory on success
@MainActor func consumeClosedTilingPosition(pid: pid_t, workspace: Workspace, now: Date = .now) -> BindingData? {
    pruneClosedTilingPositions(now: now)
    guard let i = closedTilingPositions.lastIndex(where: { $0.pid == pid && $0.parent?.nodeWorkspace === workspace }) else {
        return nil
    }
    let entry = closedTilingPositions.remove(at: i)
    guard let parent = entry.parent else { return nil }
    return BindingData(parent: parent, adaptiveWeight: entry.weight, index: min(entry.index, parent.children.count))
}

@MainActor private func pruneClosedTilingPositions(now: Date) {
    closedTilingPositions.removeAll { now.timeIntervalSince($0.closedAt) > closedTilingPositionTtl || $0.parent?.nodeWorkspace == nil }
}

@MainActor func resetClosedTilingPositionsForTests() {
    closedTilingPositions = []
}
