import Common

// Count-based deterministic layouts (fork feature, enable-count-based-layouts config option).
//
// The workspace's tiling tree is reshaped by tiling-window count (floating windows,
// popups, minimized and macOS-fullscreen windows don't participate):
//
//   2 windows -> [A | B]                 side by side
//   3 windows -> [A | (B over C)]        one primary + a stack of 2
//   4 windows -> [(A over B) | (C over D)]  2x2 grid
//   1 and 5+  -> untouched
//
// "over" is relative to the root orientation: on a horizontal root the stacks are
// vertical (the shapes above); on a vertical root the whole layout transposes.
//
// The reshape preserves the DFS order of windows and only fires when the current
// shape doesn't already match, so manual resizes (weights) survive refreshes.
// The 3-window shape accepts the stack on either side ([A | (B/C)] and [(A/B) | C])
// so `move` commands can relocate windows between columns without being snapped back.

extension Workspace {
    @MainActor func normalizeCountBasedLayout() {
        let root = rootTilingContainer
        guard root.layout == .tiles else { return }
        let windows = root.allLeafWindowsRecursive
        guard (2 ... 4).contains(windows.count) else { return }
        if matchesCountBasedShape(root: root, count: windows.count) { return }
        let mru = mostRecentWindowRecursive
        rebuildCountBasedShape(root: root, windows: windows)
        if let mru, windows.contains(where: { $0 === mru }) {
            mru.markAsMostRecentChild()
        }
    }
}

@MainActor
private func matchesCountBasedShape(root: TilingContainer, count: Int) -> Bool {
    func isStackOf2(_ node: TreeNode) -> Bool {
        guard let container = node as? TilingContainer else { return false }
        return container.orientation == root.orientation.opposite
            && container.layout == .tiles
            && container.children.count == 2
            && container.children.allSatisfy { $0 is Window }
    }
    let children = root.children
    switch count {
        case 2:
            return children.count == 2 && children.allSatisfy { $0 is Window }
        case 3:
            return children.count == 2
                && children.filter { $0 is Window }.count == 1
                && children.filter(isStackOf2).count == 1
        case 4:
            return children.count == 2 && children.allSatisfy(isStackOf2)
        default:
            return true
    }
}

@MainActor
private func rebuildCountBasedShape(root: TilingContainer, windows: [Window]) {
    for window in windows {
        window.unbindFromParent()
    }
    for leftoverContainer in root.children {
        leftoverContainer.unbindFromParent()
    }
    func bindStack(_ first: Window, _ second: Window) {
        let stack = TilingContainer(parent: root, adaptiveWeight: WEIGHT_AUTO, root.orientation.opposite, .tiles, index: INDEX_BIND_LAST)
        first.bind(to: stack, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
        second.bind(to: stack, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
    }
    switch windows.count {
        case 2:
            for window in windows {
                window.bind(to: root, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
            }
        case 3:
            windows[0].bind(to: root, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
            bindStack(windows[1], windows[2])
        case 4:
            bindStack(windows[0], windows[1])
            bindStack(windows[2], windows[3])
        default:
            break
    }
}
