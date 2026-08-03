import AppKit
import Common

/// Fork: toggle the 3-window count-based layout between the pinned side-by-side shape
/// and the stacked-on-top variant (half spanning the full width, quarters below).
/// The current half stays the half across the flip.
struct FlipCountLayoutCommand: Command {
    let args: FlipCountLayoutCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = true

    func run(_ env: CmdEnv, _ io: CmdIo) -> BinaryExitCode {
        guard config.enableCountBasedLayouts else {
            return .fail(io.err("flip-count-layout requires enable-count-based-layouts"))
        }
        guard let target = args.resolveTargetOrReportError(env, io) else { return .fail }
        let workspace = target.workspace
        let root = workspace.rootTilingContainer
        guard root.layout == .tiles else {
            return .fail(io.err("flip-count-layout requires the tiles layout"))
        }
        let windows = root.allLeafWindowsRecursive
        guard windows.count == 3 else {
            return .fail(io.err("flip-count-layout applies only to workspaces with exactly 3 tiling windows (got \(windows.count))"))
        }
        workspace.countLayoutVertical.toggle()
        // The half is the root child that is a window; if the tree is mid-churn and the
        // shape isn't canonical, fall back to DFS order (same choice normalization makes)
        let primary = root.children.first(where: { $0 is Window }) as? Window ?? windows[0]
        let stack = windows.filter { $0 !== primary }
        let mru = workspace.mostRecentWindowRecursive
        for window in windows {
            window.unbindFromParent()
        }
        for leftoverContainer in root.children {
            leftoverContainer.unbindFromParent()
        }
        rebuildCountBasedThreeShape(
            root: root,
            primary: primary,
            stack: stack,
            orientation: workspace.countLayoutVertical ? .v : .h,
        )
        if let mru, windows.contains(where: { $0 === mru }) {
            mru.markAsMostRecentChild()
        }
        return .succ
    }
}
