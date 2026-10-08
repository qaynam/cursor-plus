import AppKit
import ApplicationServices
import CoreGraphics

/// Cursor+ touches macOS privacy grants; on macOS 26 none implies another, so we
/// request each independently:
///   • Post Events  — to synthesize cursor moves + scrolls (CGPreflight/RequestPostEventAccess)
///   • Input Monitoring (ListenEvent) — for the global key tap (kill switch + auto-pause)
///   • Accessibility — the master grant that, in practice, also enables posting +
///     listening for this app. (The tool no longer reads the element under the
///     cursor — that was only for the removed safe-click system.)
///
/// All live under Settings ▸ Privacy & Security and, in practice, granting
/// "Accessibility" to this app satisfies posting + listening too — but we request
/// each properly rather than assume.
enum Permissions {

    // MARK: Post Events (move + scroll)

    @discardableResult
    static func requestPostEvents() -> Bool { CGRequestPostEventAccess() }

    // MARK: Input Monitoring (global key tap)

    @discardableResult
    static func requestListenEvents() -> Bool { CGRequestListenEventAccess() }

    // MARK: Accessibility

    @discardableResult
    static func requestAccessibility() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue()
        let options = [key: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Accessibility is usable. Trust is the real signal; we deliberately do NOT
    /// fail on a probe call (that produced false "needs permission" reports even
    /// when the grant was present).
    static var accessibilityUsable: Bool { AXIsProcessTrusted() }

    // MARK: Aggregate

    /// Ready to operate. Accessibility is the MASTER grant: it lets us post events
    /// (move/scroll) AND create the global key tap (kill switch). Input Monitoring is
    /// a separate Settings pane that Accessibility already covers for our event tap —
    /// requiring it here made the app say "needs permission" even after the user
    /// granted Accessibility. So readiness keys off Accessibility alone.
    static var allReady: Bool {
        accessibilityUsable
    }

    /// Fire the system prompts (first launch) in one go.
    static func requestAll() {
        _ = requestPostEvents()
        _ = requestListenEvents()
        _ = requestAccessibility()
    }

    /// Deep-link the user straight to Settings > Privacy & Security > Accessibility.
    static func openAccessibilitySettings() { openPrivacyPane("Privacy_Accessibility") }

    /// Settings > Privacy & Security > Input Monitoring, for when Accessibility is
    /// granted but the Esc stop's key tap still can't be created.
    static func openInputMonitoringSettings() { openPrivacyPane("Privacy_ListenEvent") }

    /// Tries the modern (macOS 13+) pane id first, falls back to the legacy scheme.
    private static func openPrivacyPane(_ anchor: String) {
        let modern = "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(anchor)"
        let legacy = "x-apple.systempreferences:com.apple.preference.security?\(anchor)"
        if let url = URL(string: modern), NSWorkspace.shared.open(url) { return }
        if let url = URL(string: legacy) { NSWorkspace.shared.open(url) }
    }

    /// Forget this app's stored Accessibility decision, so the next request adds a
    /// fresh entry. An ad-hoc signed rebuild leaves the old entry in the list,
    /// switched on but bound to the previous build, which reads as "granted" in
    /// Settings while the app is told it is not. False if the reset was refused.
    static func resetAccessibilityGrant() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        let tccutil = Process()
        tccutil.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        tccutil.arguments = ["reset", "Accessibility", bundleID]
        do {
            try tccutil.run()
            tccutil.waitUntilExit()
        } catch {
            return false
        }
        return tccutil.terminationStatus == 0
    }
}
