import AppKit
import Common

// Persist workspace assignments across server restarts (fork feature,
// persist-workspace-assignments config option).
//
// Upstream binds every window to its monitor's active workspace on startup, so any
// server restart (hot-swap deploys included) heaps all windows onto one workspace.
//
// The fix reuses the lock-screen FrozenWorld machinery: the world is snapshotted to
// a JSON state file after every refresh session (debounced, skipped when unchanged),
// and on startup the file is loaded back into closedWindowsCache. The existing
// restoreClosedWindowsCacheIfNeeded path then rebinds each window to its old
// workspace and tree position as it is detected, with all the partial-detection and
// orphan handling that path already has.
//
// CGWindowIDs are only stable within one boot session (they restart and could collide
// after a reboot), so the file records kern.boottime and is discarded on mismatch.
// This intentionally covers WM restarts/crashes, not machine reboots.

// MARK: - Persisted schema (Codable mirror of the Frozen* types)

struct PersistedWorld: Codable {
    /// kern.boottime seconds since epoch — guards against CGWindowID reuse across reboots
    let bootTime: Int
    let workspaces: [PersistedWorkspace]
    let monitors: [PersistedMonitor]
    /// Optional so files written by older fork builds still decode
    let focusedWorkspace: String?
}

struct PersistedMonitor: Codable {
    let topLeftX: Double
    let topLeftY: Double
    let visibleWorkspace: String
}

struct PersistedWorkspace: Codable {
    let name: String
    let monitor: PersistedMonitor
    let rootTilingNode: PersistedContainer
    let floatingWindows: [PersistedWindow]
    let macosUnconventionalWindows: [PersistedWindow]
}

struct PersistedWindow: Codable {
    let id: UInt32
    let weight: Double
}

struct PersistedContainer: Codable {
    let children: [PersistedTreeNode]
    let layout: String
    let orientation: String
    let weight: Double
}

enum PersistedTreeNode: Codable {
    case container(PersistedContainer)
    case window(PersistedWindow)
}

// MARK: - FrozenWorld -> PersistedWorld

extension PersistedWorld {
    init(_ world: FrozenWorld, bootTime: Int, focusedWorkspace: String?) {
        self.bootTime = bootTime
        self.workspaces = world.workspaces.map(PersistedWorkspace.init)
        self.monitors = world.monitors.map(PersistedMonitor.init)
        self.focusedWorkspace = focusedWorkspace
    }
}

extension PersistedMonitor {
    init(_ monitor: FrozenMonitor) {
        topLeftX = monitor.topLeftCorner.x
        topLeftY = monitor.topLeftCorner.y
        visibleWorkspace = monitor.visibleWorkspace
    }
}

extension PersistedWorkspace {
    init(_ workspace: FrozenWorkspace) {
        name = workspace.name
        monitor = PersistedMonitor(workspace.monitor)
        rootTilingNode = PersistedContainer(workspace.rootTilingNode)
        floatingWindows = workspace.floatingWindows.map(PersistedWindow.init)
        macosUnconventionalWindows = workspace.macosUnconventionalWindows.map(PersistedWindow.init)
    }
}

extension PersistedWindow {
    init(_ window: FrozenWindow) {
        id = window.id
        weight = window.weight
    }
}

extension PersistedContainer {
    init(_ container: FrozenContainer) {
        children = container.children.map {
            switch $0 {
                case .container(let c): .container(PersistedContainer(c))
                case .window(let w): .window(PersistedWindow(w))
            }
        }
        layout = container.layout.rawValue
        orientation = container.orientation == .h ? "h" : "v"
        weight = container.weight
    }
}

// MARK: - PersistedWorld -> FrozenWorld

extension PersistedWorld {
    /// nil if the file references layouts/orientations this build doesn't know (schema drift)
    func toFrozenWorld() -> FrozenWorld? {
        var frozenWorkspaces: [FrozenWorkspace] = []
        for workspace in workspaces {
            guard let frozen = workspace.toFrozen() else { return nil }
            frozenWorkspaces.append(frozen)
        }
        let windowIds = frozenWorkspaces.flatMap { workspace in
            collectWindowIds(workspace.rootTilingNode) +
                workspace.floatingWindows.map(\.id) +
                workspace.macosUnconventionalWindows.map(\.id)
        }
        return FrozenWorld(
            workspaces: frozenWorkspaces,
            monitors: monitors.map { $0.toFrozen() },
            windowIds: windowIds.toSet(),
        )
    }
}

private func collectWindowIds(_ container: FrozenContainer) -> [UInt32] {
    container.children.flatMap { child -> [UInt32] in
        switch child {
            case .container(let c): collectWindowIds(c)
            case .window(let w): [w.id]
        }
    }
}

extension PersistedMonitor {
    fileprivate func toFrozen() -> FrozenMonitor {
        FrozenMonitor(
            topLeftCorner: CGPoint(x: topLeftX, y: topLeftY),
            visibleWorkspace: visibleWorkspace,
        )
    }
}

extension PersistedWorkspace {
    fileprivate func toFrozen() -> FrozenWorkspace? {
        guard let root = rootTilingNode.toFrozen() else { return nil }
        return FrozenWorkspace(
            name: name,
            monitor: monitor.toFrozen(),
            rootTilingNode: root,
            floatingWindows: floatingWindows.map { $0.toFrozen() },
            macosUnconventionalWindows: macosUnconventionalWindows.map { $0.toFrozen() },
        )
    }
}

extension PersistedWindow {
    fileprivate func toFrozen() -> FrozenWindow {
        FrozenWindow(id: id, weight: weight)
    }
}

extension PersistedContainer {
    fileprivate func toFrozen() -> FrozenContainer? {
        guard let layout = Layout(rawValue: layout) else { return nil }
        let orientation: Orientation? = switch self.orientation {
            case "h": .h
            case "v": .v
            default: nil
        }
        guard let orientation else { return nil }
        var frozenChildren: [FrozenTreeNode] = []
        for child in children {
            switch child {
                case .container(let c):
                    guard let frozen = c.toFrozen() else { return nil }
                    frozenChildren.append(.container(frozen))
                case .window(let w):
                    frozenChildren.append(.window(w.toFrozen()))
            }
        }
        return FrozenContainer(children: frozenChildren, layout: layout, orientation: orientation, weight: weight)
    }
}

// MARK: - Disk IO

// aeroSpaceAppId in the name keeps debug (bobko.aerospace.debug) and release servers
// from clobbering each other's state during hot-swap validation sessions
var workspaceStateFileUrl: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        .appending(component: "AeroSpace")
        .appending(component: "workspace-state-\(aeroSpaceAppId).json")
}

func getBootTime() -> Int? {
    var bootTimeval = timeval()
    var size = MemoryLayout<timeval>.size
    return unsafe sysctlbyname("kern.boottime", &bootTimeval, &size, nil, 0) == 0 ? Int(bootTimeval.tv_sec) : nil
}

// kern.boottime is derived from wall clock minus uptime, so NTP adjustments can shift
// it by seconds within one boot session. Reboots take minutes, so a couple of minutes
// of tolerance can't confuse two different boot sessions
private let bootTimeToleranceSeconds = 120

@MainActor private var persistWorkspaceStateTask: Task<(), any Error>? = nil
@MainActor private var lastPersistedData: Data? = nil

@MainActor func schedulePersistWorkspaceState() {
    if isUnitTest || !config.persistWorkspaceAssignments { return }
    persistWorkspaceStateTask?.cancel()
    persistWorkspaceStateTask = Task { @MainActor in
        try await Task.sleep(for: .milliseconds(500))
        persistWorkspaceStateNow()
    }
}

@MainActor func persistWorkspaceStateNow() {
    if isUnitTest || !config.persistWorkspaceAssignments { return }
    // Persist-under-load guard (observed live 2026-07-30, ROADMAP backlog): while any app is
    // AX-quarantined the model may hold mis-bound windows - degraded enumerations fall back to
    // last-known ids, and a briefly-stalled app's new windows can bind to the focused workspace.
    // A snapshot taken now can replace a good file with a wrong map that the next restart
    // faithfully restores. Skip the write; quarantine backoff is 1.5s, so the next healthy
    // session persists the truth. Checked here (not at schedule time) so the state after the
    // 500ms debounce decides, and so the beforeTermination flush is gated by the same rule.
    if MacApp.allAppsMap.values.contains(where: \.isAxQuarantined) { return }
    guard let bootTime = getBootTime() else { return }
    let world = FrozenWorld(
        workspaces: Workspace.all.map { FrozenWorkspace($0) },
        monitors: monitors.map(FrozenMonitor.init),
        windowIds: [], // derived on load, not persisted
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys // deterministic bytes for the unchanged-skip below
    let data: Data
    do {
        data = try encoder.encode(PersistedWorld(world, bootTime: bootTime, focusedWorkspace: focus.workspace.name))
    } catch {
        FileHandle.standardError.write("Failed to encode workspace state: \(error)\n".data(using: .utf8)!)
        return
    }
    if data == lastPersistedData { return }
    let url = workspaceStateFileUrl
    do {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        lastPersistedData = data
    } catch {
        FileHandle.standardError.write("Failed to write workspace state to \(url.path): \(error)\n".data(using: .utf8)!)
    }
}

/// Startup: seed closedWindowsCache with the persisted world so that
/// restoreClosedWindowsCacheIfNeeded rebinds windows as they are detected
@MainActor func seedPersistedWorkspaceStateAtStartup() {
    if isUnitTest || !config.persistWorkspaceAssignments { return }
    let url = workspaceStateFileUrl
    guard let data = try? Data(contentsOf: url) else { return } // no state yet — first run
    guard let persisted = try? JSONDecoder().decode(PersistedWorld.self, from: data) else {
        FileHandle.standardError.write("Ignoring unparsable workspace state at \(url.path)\n".data(using: .utf8)!)
        return
    }
    guard let bootTime = getBootTime(), abs(persisted.bootTime - bootTime) <= bootTimeToleranceSeconds else {
        return // state is from a previous boot session — window ids may be recycled
    }
    guard let world = persisted.toFrozenWorld() else {
        FileHandle.standardError.write("Ignoring workspace state at \(url.path): unknown layout/orientation\n".data(using: .utf8)!)
        return
    }
    persistedStartupFocusedWorkspace = persisted.focusedWorkspace
    seedClosedWindowsCache(world)
}

/// The workspace to re-focus while startup restore runs. Left set after startup —
/// harmless, since the restore path only consults it while isStartup is true
@MainActor var persistedStartupFocusedWorkspace: String? = nil
