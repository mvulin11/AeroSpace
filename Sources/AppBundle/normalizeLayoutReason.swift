import AppKit
import Common

// Test seam for the ordered-out (background native tab) detection
@MainActor var orderedOutWindowIdsForTests: Set<UInt32>? = nil

// nil = no information (feature off, unit test without a seam value, or screen locked —
// the lock screen makes windows unobservable and must not be mistaken for tab churn).
// With nil, windows are neither shelved as background tabs nor restored on that basis
@MainActor private func detectOrderedOutWindowIds() -> Set<UInt32>? {
    if isUnitTest { return orderedOutWindowIdsForTests }
    if !config.excludeBackgroundTabs { return nil }
    if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == lockScreenAppBundleId { return nil }
    let onScreen = getOnScreenWindowIds()
    return MacWindow.allWindowsMap.keys.filter { !onScreen.contains($0) }.toSet()
}

@MainActor
func normalizeLayoutReason() async throws {
    let orderedOutIds = detectOrderedOutWindowIds()
    for workspace in Workspace.all {
        let windows: [Window] = workspace.allLeafWindowsRecursive
        try await _normalizeLayoutReason(workspace: workspace, windows: windows, orderedOutIds: orderedOutIds)
    }
    try await _normalizeLayoutReason(workspace: focus.workspace, windows: macosMinimizedWindowsContainer.children.filterIsInstance(of: Window.self), orderedOutIds: orderedOutIds)
    try await validateStillPopups()
}

@MainActor
private func validateStillPopups() async throws {
    for node in macosPopupWindowsContainer.children {
        let popup = (node as! MacWindow)
        let windowLevel = getWindowLevel(for: popup.windowId)
        if try await popup.isWindowHeuristic(windowLevel, .cancellable) {
            try await popup.relayoutWindow(on: focus.workspace, .cancellable)
            await tryOnWindowDetected(popup)
        }
    }
}

@MainActor
private func _normalizeLayoutReason(workspace: Workspace, windows: [Window], orderedOutIds: Set<UInt32>?) async throws {
    for window in windows {
        let isMacosFullscreen = try await window.isMacosFullscreen(.cancellable)
        let isMacosMinimized = try await (!isMacosFullscreen).andAsync { @MainActor @Sendable in try await window.isMacosMinimized(.cancellable) }
        let isMacosWindowOfHiddenApp = !isMacosFullscreen && !isMacosMinimized &&
            !config.automaticallyUnhideMacosHiddenApps && window.macAppUnsafe.nsApp.isHidden
        // Ordered out of the window server while not fullscreen/minimized/hidden = a
        // background macOS-native tab (Ghostty, Finder, ...). Order matters: fullscreen
        // windows live on their own Space and also read as not-onscreen, so this check
        // must stay LAST. Shelve like a minimized window; restored when ordered back in
        let isMacosBackgroundTab = !isMacosFullscreen && !isMacosMinimized && !isMacosWindowOfHiddenApp &&
            orderedOutIds?.contains(window.windowId) == true
        switch window.layoutReason {
            case .standard:
                guard let parent = window.parent else { continue }
                switch true {
                    case isMacosFullscreen:
                        window.layoutReason = .macos(prevParentKind: parent.kind)
                        window.bind(to: workspace.macOsNativeFullscreenWindowsContainer, adaptiveWeight: WEIGHT_DOESNT_MATTER, index: INDEX_BIND_LAST)
                    case isMacosMinimized:
                        window.layoutReason = .macos(prevParentKind: parent.kind)
                        window.bind(to: macosMinimizedWindowsContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
                    case isMacosWindowOfHiddenApp:
                        window.layoutReason = .macos(prevParentKind: parent.kind)
                        window.bind(to: workspace.macOsNativeHiddenAppsWindowsContainer, adaptiveWeight: WEIGHT_DOESNT_MATTER, index: INDEX_BIND_LAST)
                    case isMacosBackgroundTab:
                        // Remember the vacated spot so the group's newly active tab (or this
                        // window itself, on switch-back) can reclaim it
                        if let tilingParent = parent as? TilingContainer, let index = window.ownIndex {
                            recordClosedTilingPosition(pid: window.app.pid, parent: tilingParent, index: index, weight: window.getWeight(tilingParent.orientation))
                        }
                        window.layoutReason = .macos(prevParentKind: parent.kind)
                        window.bind(to: macosMinimizedWindowsContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
                    default: break
                }
            case .macos(let prevParentKind):
                if !isMacosFullscreen && !isMacosMinimized && !isMacosWindowOfHiddenApp && !isMacosBackgroundTab {
                    try await exitMacOsNativeUnconventionalState(window: window, prevParentKind: prevParentKind, workspace: workspace, .cancellable)
                }
        }
    }
}

@MainActor
func exitMacOsNativeUnconventionalState(
    window: Window,
    prevParentKind: NonLeafTreeNodeKind,
    workspace: Workspace,
    _ cm: CancellationMode,
) async throws {
    window.layoutReason = .standard
    switch prevParentKind {
        case .floatingWindowsContainer:
            window.bindAsFloatingWindow(to: workspace)
        case .workspace:
            break // Not possible
        case .tilingContainer:
            try await window.relayoutWindow(on: workspace, cm, forceTile: true)
        case .macosPopupWindowsContainer: // Since the window was minimized/fullscreened it was mistakenly detected as popup. Relayout the window
            try await window.relayoutWindow(on: workspace, cm)
        case .macosMinimizedWindowsContainer, .macosFullscreenWindowsContainer, .macosHiddenAppsWindowsContainer: // wtf case, should never be possible. But If encounter it, let's just re-layout window
            try await window.relayoutWindow(on: workspace, cm)
    }
}
