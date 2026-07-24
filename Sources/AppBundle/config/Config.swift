import AppKit
import Common
import HotKey
import OrderedCollections

func getDefaultConfigUrlFromProject() -> URL {
    var url = URL(filePath: #filePath)
    check(FileManager.default.fileExists(atPath: url.path))
    while !FileManager.default.fileExists(atPath: url.appending(component: ".git").path) {
        url.deleteLastPathComponent()
    }
    let projectRoot: URL = url
    return projectRoot.appending(component: "docs/config-examples/default-config.toml")
}

var defaultConfigUrl: URL {
    if isUnitTest {
        return getDefaultConfigUrlFromProject()
    } else {
        return Bundle.main.url(forResource: "default-config", withExtension: "toml")
            // Useful for debug builds that are not app bundles
            ?? getDefaultConfigUrlFromProject()
    }
}
@MainActor let defaultConfig: Config = {
    let parsedConfig = parseConfig(Result { try String(contentsOf: defaultConfigUrl, encoding: .utf8) }.getOrDie())
    if !parsedConfig.errors.isEmpty {
        die("Can't parse default config: \(parsedConfig.errors)")
    }
    return parsedConfig.config
}()
@MainActor var config: Config = defaultConfig // todo move to Ctx?
@MainActor var configUrl: URL = defaultConfigUrl

struct Config: ConvenienceMutable {
    var configVersion: ConfigVersion = ._1
    var _afterLoginCommand: [any Command] = []
    var afterStartupCommand: Shell<any Command> = .empty
    var _indentForNestedContainersWithTheSameOrientation: Void = ()
    var enableNormalizationFlattenContainers: Bool = true
    var _nonEmptyWorkspacesRootContainersLayoutOnStartup: Void = ()
    var defaultRootContainerLayout: Layout = .tiles
    var defaultRootContainerOrientation: DefaultContainerOrientation = .auto
    var startAtLogin: Bool = false
    var autoReloadConfig: Bool = false
    var automaticallyUnhideMacosHiddenApps: Bool = false
    var accordionPadding: Int = 30
    var enableNormalizationOppositeOrientationForNestedContainers: Bool = true
    // Fork feature: deterministic count-based layouts (2=side-by-side, 3=primary+stack, 4=2x2)
    var enableCountBasedLayouts: Bool = false
    // Fork feature: center non-resizable windows (System Settings, Calculator, ...) in their tile
    var centerNonResizableWindows: Bool = true
    // Fork feature: restore windowId -> workspace assignments after a server restart (state file survives WM restarts, not reboots)
    var persistWorkspaceAssignments: Bool = true
    // Fork feature (#1615): deadline for AX requests to one app before the session degrades
    // to that app's last known state instead of stalling every app. 0 disables (stock behavior)
    var axAppTimeoutMs: Int = 2000
    // Fork feature: deadline for the per-app window enumeration probe specifically. Much
    // shorter than axAppTimeoutMs because this one call site gates every reflow: closing or
    // minimizing a window can't re-tile the survivors until the enumeration returns for ALL
    // apps, so one unresponsive app anywhere on the system (even with no window on the visible
    // monitor) used to add the whole axAppTimeoutMs to every reflow. Degrading here is benign
    // and already designed for — last known window ids, quarantine, self-heal on the next
    // probe — so this deadline buys latency at almost no correctness cost. Deliberate AX work
    // (setFrame, focus, close) keeps the patient axAppTimeoutMs. 0 = reuse axAppTimeoutMs
    var axRefreshTimeoutMs: Int = 250
    // Fork feature: shelve background macOS-native tab windows (Ghostty, Finder, ...) out of
    // the tiling tree so creating/switching tabs doesn't reshape the workspace
    var excludeBackgroundTabs: Bool = true
    var persistentWorkspaces: OrderedSet<String> = []
    var execOnWorkspaceChange: [String] = [] // todo deprecate
    var keyMapping = KeyMapping()
    var execConfig: ExecConfig = ExecConfig()
    var focusFollowsMouse: FocusFollowsMouse = FocusFollowsMouse()

    var onFocusChanged: Shell<any Command> = .empty
    // var onFocusedWorkspaceChanged: [any Command] = []
    var onFocusedMonitorChanged: Shell<any Command> = .empty

    var gaps: Gaps = .zero
    var workspaceToMonitorForceAssignment: [String: [MonitorDescription]] = [:]
    var modes: [String: Mode] = [:]
    var onWindowDetected: [WindowDetectedCallback] = []
    var onModeChanged: Shell<any Command> = .empty
}

struct FocusFollowsMouse: ConvenienceMutable {
    var enabled: Bool = false
}

enum ConfigVersion: Int, Comparable, CaseIterable, Sendable, CustomStringConvertible {
    case _1 = 1
    case _2 = 2

    static let max = allCases.max().orDie()
    static let min = allCases.min().orDie()
    static func < (lhs: ConfigVersion, rhs: ConfigVersion) -> Bool { lhs.rawValue < rhs.rawValue }

    var description: String { rawValue.description }
}

enum DefaultContainerOrientation: String {
    case horizontal, vertical, auto
}
