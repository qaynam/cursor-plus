import Foundation
import CoreGraphics

/// Tracks the last time the *real* user did something (mouse/keyboard), so the
/// state machine can pause the bot the instant the user takes over and resume
/// only after a quiet cooldown. All access is on the main thread.
final class AutoPause {

    /// Monotonic timestamp of the last real user input, or 0 if none yet seen.
    private(set) var lastActivity: TimeInterval = 0

    /// Call from the event tap whenever a *real* (non-synthetic) input arrives.
    func markActivity() {
        lastActivity = ProcessInfo.processInfo.systemUptime
    }

    /// True while we should stay paused: the user has been active within `cooldown`.
    func shouldPause(cooldown: TimeInterval) -> Bool {
        guard lastActivity > 0 else { return false }
        return (ProcessInfo.processInfo.systemUptime - lastActivity) < cooldown
    }

    /// Pick up the user's idle time from before a session started, so a start honours
    /// the idle delay too: clicking Start waits the full delay, while a trigger that
    /// fires after you have been away for longer starts right away.
    ///
    /// Reads the system's own HID idle clock, which our posted motion also resets, so
    /// after a recent session it reads short. That only ever means waiting longer,
    /// never starting while the user is still at the mouse.
    func seedFromSystemIdle() {
        let anyInput = CGEventType(rawValue: ~0)!   // kCGAnyInputEventType
        let idle = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: anyInput)
        guard idle.isFinite, idle >= 0 else { return }
        lastActivity = max(lastActivity, ProcessInfo.processInfo.systemUptime - idle)
    }
}
