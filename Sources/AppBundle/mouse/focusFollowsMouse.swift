import AppKit

@MainActor private var focusFollowsMouseMonitor: Any? = nil
@MainActor private var focusFollowsTask: Task<(), any Error>? = nil
@MainActor private var focusFollowsMouseSuppressedUntil: Date = .distantPast

/// Generous next to the few ms it takes a posted CGEvent to come back around to our
/// monitor, short enough that a user actively moving the mouse won't notice the gap.
private let focusFollowsMouseWarpGrace: TimeInterval = 0.25

/// Called by `move-mouse` immediately before it warps the cursor.
///
/// AeroSpace warps by *posting a real `.mouseMoved` CGEvent* (see `MoveMouseCommand`), so by
/// the time it reaches our global `NSEvent` monitor it is indistinguishable from a human
/// moving the mouse. Acting on it makes focus follow a position AeroSpace picked rather than
/// one the user picked, which is how `move-mouse` ends up stealing focus: on a workspace
/// switch the warp can land in the off-screen band where hidden windows park (upstream #386),
/// and focus-follows-mouse then focuses a parked window, dragging it into the visible
/// workspace.
///
/// Suppressing by time rather than by matching the warp coordinates keeps this free of
/// coordinate-space assumptions — the monitor sees flipped `NSEvent` coordinates while the
/// warp target is in top-left layout space — at the cost of ignoring genuine pointer motion
/// for a moment after each warp.
@MainActor func suppressFocusFollowsMouseForWarp(now: Date = .now) {
    focusFollowsMouseSuppressedUntil = now + focusFollowsMouseWarpGrace
}

@MainActor func syncFocusFollowsMouse(_ config: Config) {
    if config.focusFollowsMouse.enabled == (focusFollowsMouseMonitor != nil) {
        return
    }

    if !config.focusFollowsMouse.enabled {
        NSEvent.removeMonitor(focusFollowsMouseMonitor.orDie())
        focusFollowsMouseMonitor = nil
        focusFollowsTask?.cancel()
        focusFollowsTask = nil
        return
    }

    // Interestingly, this callback seems to not fire when the mouse is down which is good,
    // because this is how I want it to work for windows/tabs/files dragging
    focusFollowsMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { @MainActor event in
        // Our own cursor warp echoing back. It isn't user intent, so it must not move focus.
        if Date.now < focusFollowsMouseSuppressedUntil { return }
        let location = event.locationInWindow.withYAxisFlipped
        focusFollowsTask?.cancel()
        focusFollowsTask = Task.startUnstructured { @MainActor in
            guard let token: RunSessionGuard = .isServerEnabled else { return }
            try checkCancellation()
            // Ignores macOS menubar dropdown, but, unfortunately, it doesn't ignore non-native menu-like fake windows.
            // todo: It would be cool to somehow reuse isWindowHeuristic logic here
            if await isAxWindowUnderMouse(location) == false { return }
            try checkCancellation()
            let workspace = location.monitorApproximation.activeWorkspace
            var window: Window? = nil
            for child in workspace.floatingWindowsContainer.mruChildren {
                try checkCancellation()
                guard let child = child as? Window else { continue }
                guard let rect = try await child.getAxRect(.cancellable) else { continue }
                if rect.contains(location) {
                    window = child
                    break
                }
            }
            if window == nil {
                window = location.findWindowRecursively(in: workspace.rootTilingContainer, virtual: false, fullscreenCoversAll: true)
            }
            if let window {
                try await runLightSession(.focusFollowsMouse, token) {
                    _ = window.focusWindow()
                    window.nativeFocus()
                }
            }
        }
    }
}

@concurrent
private nonisolated func isAxWindowUnderMouse(_ location: CGPoint) async -> Bool? {
    let systemwide = AXUIElementCreateSystemWide()
    var element: AXUIElement?
    if unsafe AXUIElementCopyElementAtPosition(systemwide, Float(location.x), Float(location.y), &element) != .success {
        return nil
    }
    guard let element else { return nil }
    return element.get(Ax.parentWindowRecursive) != nil || element.get(Ax.roleAttr) == kAXWindowRole
}
