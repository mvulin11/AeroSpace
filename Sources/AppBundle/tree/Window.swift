import AppKit
import Common

open class Window: TreeNode, Hashable {
    let windowId: UInt32
    let app: any AbstractApp
    var lastFloatingSize: CGSize?
    var isFullscreen: Bool = false
    var noOuterGapsInFullscreen: Bool = false
    var layoutReason: LayoutReason = .standard

    @MainActor
    init(id: UInt32, _ app: any AbstractApp, lastFloatingSize: CGSize?, parent: NonLeafTreeNodeObject, adaptiveWeight: CGFloat, index: Int) {
        self.windowId = id
        self.app = app
        self.lastFloatingSize = lastFloatingSize
        super.init(parent: parent, adaptiveWeight: adaptiveWeight, index: index)
    }

    @MainActor static func get(byId windowId: UInt32) -> Window? { // todo make non optional
        isUnitTest
            ? Workspace.all.flatMap { $0.allLeafWindowsRecursive }.first(where: { $0.windowId == windowId })
            : MacWindow.allWindowsMap[windowId]
    }

    @MainActor
    func closeAxWindow() { die("Not implemented") }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(windowId)
    }

    func getAxSize(_ cm: CancellationMode) async throws -> CGSize? { die("Not implemented") }
    // Non-resizable (or partially resizable, e.g. fixed-width System Settings) windows
    // clamp the size part of setAxFrame. AX doesn't expose per-axis resizability, so
    // clamping is observed: returns the actual size when the window clamps, nil when it
    // conforms to the requested size. Implementations cache the classification after the
    // first observation, so conforming windows pay for one readback in their lifetime
    func getAxSizeIfClamping(target: CGSize, _ cm: CancellationMode) async throws -> CGSize? { nil }
    // Last observed clamped size of a known-clamping window, nil for conforming/unknown.
    // Lets the layout place clamping windows at their centered position directly instead
    // of positioning at the tile's top-left first and re-centering after the readback
    var knownClampedAxSize: CGSize? { nil }
    func getTitle(_ cm: CancellationMode) async throws -> String { die("Not implemented") }
    func isMacosFullscreen(_ cm: CancellationMode) async throws -> Bool { false }
    func isMacosMinimized(_ cm: CancellationMode) async throws -> Bool { false } // todo replace with enum MacOsWindowNativeState { normal, fullscreen, invisible }
    var isHiddenInCorner: Bool { die("Not implemented") }
    @MainActor func nativeFocus() { die("Not implemented") }
    func getAxRect(_ cm: CancellationMode) async throws -> Rect? { die("Not implemented") }
    func getCenter(_ cm: CancellationMode) async throws -> CGPoint? { try await getAxRect(cm)?.center }

    func setAxFrame(_ topLeft: CGPoint?, _ size: CGSize?) { die("Not implemented") }
}

enum LayoutReason: Equatable {
    case standard
    /// Reason for the cur temp layout is macOS native fullscreen, minimize, or hide
    ///
    /// `restoreToWorkspace` is the workspace to put the window back on, and is set only for
    /// background native tabs. Fullscreen and hidden-app windows are shelved in per-workspace
    /// containers that already carry that information, and a minimized window is expected to
    /// come back wherever the user un-minimizes it. A background tab is different: it is shelved
    /// in the GLOBAL minimized container by nothing the user did, so without remembering the
    /// workspace it gets restored into whatever happens to be focused when macOS orders it back
    /// in — which walks the whole tab group over to the workspace you are currently looking at
    case macos(prevParentKind: NonLeafTreeNodeKind, restoreToWorkspace: String?)
}

extension Window {
    var isFloating: Bool { // todo drop. It will be a source of bugs when sticky is introduced
        switch windowParentCases {
            case .floatingWindowsContainer: true
            case .macosFullscreenWindowsContainer: false
            case .macosHiddenAppsWindowsContainer: false
            case .macosMinimizedWindowsContainer: false
            case .macosPopupWindowsContainer: false
            case .tilingContainer: false
            case .unbound: false
        }
    }

    @discardableResult
    @MainActor
    func bindAsFloatingWindow(to workspace: Workspace) -> BindingData? {
        bind(to: workspace.floatingWindowsContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
    }

    func asMacWindow() -> MacWindow { self as! MacWindow }
}
