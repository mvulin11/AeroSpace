import AppKit
import Common

// Close/reopen position inheritance: MacWindow.garbageCollect records the vacated tiling
// position of EVERY closed tiling window, and the next new window of the same app on that
// workspace (cmd+W -> new window, an app replacing one of its own windows) reclaims the
// exact spot - parent, index, and size - instead of binding via the MRU heuristic.
// Originally built for macOS-native tab churn (tabs retired 2026-07-28; the shelve-path
// producer is gone with excludeBackgroundTabs defaulting off), but the close/reopen
// behavior is why this stays.

struct ClosedTilingPosition {
    let pid: pid_t
    weak var parent: TilingContainer?
    let index: Int
    /// Fraction of the parent's total weight this window held, NOT its absolute weight.
    /// Absolute weights are point-space and only meaningful against the sibling set they were
    /// measured with: layoutTiles rewrites every child's weight on each pass so the sum equals
    /// the container's size, so once the vacated space is absorbed the survivors' weights have
    /// grown and a replayed absolute weight lands on a different scale. Storing the share makes
    /// the restore scale-invariant — see consumeClosedTilingPosition
    let share: CGFloat
    let closedAt: Date
}

@MainActor private var closedTilingPositions: [ClosedTilingPosition] = []
// Tab transitions complete within one or two refresh sessions; anything older is likely
// an unrelated close and should fall back to the MRU heuristic
private let closedTilingPositionTtl: TimeInterval = 5
private let closedTilingPositionCap = 20

/// `weight` is the window's absolute weight and it must still be bound to `parent` — the share
/// is taken against the sibling set it was actually measured with
@MainActor func recordClosedTilingPosition(pid: pid_t, parent: TilingContainer, index: Int, weight: CGFloat, now: Date = .now) {
    pruneClosedTilingPositions(now: now)
    let total = CGFloat(parent.children.sumOfDouble { $0.getWeight(parent.orientation) })
    let share = total > 0 ? weight / total : 0
    closedTilingPositions = Array(closedTilingPositions.suffix(closedTilingPositionCap - 1))
    closedTilingPositions.append(ClosedTilingPosition(pid: pid, parent: parent, index: index, share: share, closedAt: now))
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
    // Solve for the absolute weight w that lands on the remembered share once layoutTiles has
    // run. That pass keeps the children's weights summing to the container size T by adding the
    // SAME delta to every child, not by scaling them, so w does not survive as-is:
    //   after binding, sum = S + w over n+1 children, and S == T (the previous pass left it so)
    //   delta = (T - (S + w)) / (n + 1) = -w / (n + 1)
    //   final = w + delta = w * n / (n + 1),  so  share = w * n / ((n + 1) * T)
    // Inverting gives w = share * S * (n + 1) / n. Naively binding share * S instead would land
    // low by a factor of n/(n+1) and drift further on each cycle
    let n = parent.children.count
    let siblings = CGFloat(parent.children.sumOfDouble { $0.getWeight(parent.orientation) })
    // share >= 1 means it was the sole child, so there is no fraction to restore against the
    // siblings that exist now; share <= 0 and an empty/weightless parent are degenerate. All of
    // them fall back to the even split WEIGHT_AUTO gives
    let weight = n > 0 && siblings > 0 && entry.share > 0 && entry.share < 1
        ? entry.share * siblings * CGFloat(n + 1) / CGFloat(n)
        : WEIGHT_AUTO
    return BindingData(parent: parent, adaptiveWeight: weight, index: min(entry.index, n))
}

@MainActor private func pruneClosedTilingPositions(now: Date) {
    closedTilingPositions.removeAll { now.timeIntervalSince($0.closedAt) > closedTilingPositionTtl || $0.parent?.nodeWorkspace == nil }
}

@MainActor func resetClosedTilingPositionsForTests() {
    closedTilingPositions = []
}
