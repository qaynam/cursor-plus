import Foundation

/// Keeps a second copy of Cursor+ from running next to the first.
///
/// Two copies each own an event tap and a menu-bar icon, and each reads the
/// other's motion as the user's. Quitting one leaves the other still moving the
/// cursor, which looks exactly like an app that refuses to quit. A stale copy at a
/// second path (the build folder, an old install, a bare `swift run` binary) is the
/// usual way this happens.
///
/// An advisory file lock rather than a bundle-ID lookup, so it covers the bare
/// binary as well. The kernel drops the lock when the process dies, however it
/// dies, so a crash can never leave the app unable to start.
enum SingleInstance {

    /// Posted by a copy that lost the race, asking the running one to show its menu.
    static let showMenuNotification = Notification.Name("com.aus.cursorplus.showMenu")

    /// Held open for the life of the process; closing it would release the lock.
    private static var lockFD: Int32 = -1

    /// True if this process is now the only Cursor+.
    static func acquire() -> Bool {
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("com.aus.cursorplus.lock")
        let fd = open(path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return true }   // unlockable: never block launch over it
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            return false
        }
        lockFD = fd
        return true
    }

    static func notifyRunningInstance() {
        DistributedNotificationCenter.default().postNotificationName(
            showMenuNotification, object: nil, userInfo: nil, deliverImmediately: true)
    }
}
