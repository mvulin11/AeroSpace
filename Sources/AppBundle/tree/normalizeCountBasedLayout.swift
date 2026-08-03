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
// vertical (the shapes above); on a vertical root the layout transposes.
//
// The 3-window shape is PINNED to a horizontal root (side-by-side: half + stack of 2,
// stack on either side) - a `move` that would leave the workspace stacked-on-top
// ([A / (B|C)], half spanning the full width) is snapped back. The transposed variant
// is only reachable through the `flip-count-layout` command, which sets the
// workspace's countLayoutVertical flag; the flag clears whenever the workspace grows
// past 3 tiling windows. 2- and 4-window shapes stay orientation-agnostic.
//
// The reshape preserves the DFS order of windows and only fires when the current
// shape doesn't already match, so manual resizes (weights) survive refreshes.

extension Workspace {
    @MainActor func normalizeCountBasedLayout() {
        let root = rootTilingContainer
        guard root.layout == .tiles else { return }
        let windows = root.allLeafWindowsRecursive
        if windows.count > 3 { countLayoutVertical = false }
        guard (2 ... 4).contains(windows.count) else { return }
        let requiredThreeOrientation: Orientation = countLayoutVertical ? .v : .h
        if matchesCountBasedShape(root: root, count: windows.count),
           windows.count != 3 || root.orientation == requiredThreeOrientation
        {
            return
        }
        let mru = mostRecentWindowRecursive
        rebuildCountBasedShape(root: root, windows: windows, threeOrientation: requiredThreeOrientation)
        if let mru, windows.contains(where: { $0 === mru }) {
            mru.markAsMostRecentChild()
        }
    }
}

@MainActor
func matchesCountBasedShape(root: TilingContainer, count: Int) -> Bool {
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
private func rebuildCountBasedShape(root: TilingContainer, windows: [Window], threeOrientation: Orientation) {
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
            rebuildCountBasedThreeShape(root: root, primary: windows[0], stack: Array(windows[1...]), orientation: threeOrientation)
        case 4:
            bindStack(windows[0], windows[1])
            bindStack(windows[2], windows[3])
        default:
            break
    }
}

/// Bind `primary` + a stack of the two `stack` windows onto the (emptied) root with the
/// given root orientation. Shared by normalization and the flip-count-layout command
/// (the command chooses `primary` = the current half, so flipping keeps it the half).
@MainActor
func rebuildCountBasedThreeShape(root: TilingContainer, primary: Window, stack: [Window], orientation: Orientation) {
    root.changeOrientation(orientation)
    primary.bind(to: root, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
    let stackContainer = TilingContainer(parent: root, adaptiveWeight: WEIGHT_AUTO, root.orientation.opposite, .tiles, index: INDEX_BIND_LAST)
    for window in stack {
        window.bind(to: stackContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
    }
}
