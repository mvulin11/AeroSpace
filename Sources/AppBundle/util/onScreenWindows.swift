import AppKit

/// Window ids currently ordered IN at the window server.
///
/// Background macOS-native tabs (and other ordered-out windows) are absent from this list.
/// AeroSpace's own corner-parked hidden-workspace windows stay ordered in (verified
/// empirically 2026-07-24: every parked window reported onscreen=true while a background
/// tab reported false), so everything AeroSpace manages is expected to be present
func getOnScreenWindowIds() -> Set<UInt32> {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    return list.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value }.toSet()
}
