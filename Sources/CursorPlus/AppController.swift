import AppKit
import Carbon   // IsSecureEventInputEnabled()
import IOKit.pwr_mgt
import ServiceManagement

/// Speed-class weight presets [verySlow, slow, normal, fast, veryFast].
private let speedPresets: [[Double]] = [
    [5, 4, 2, 1, 0.5],   // 0 Calm
    [2, 3, 4, 2, 1],     // 1 Balanced (default)
    [1, 2, 3, 4, 2],     // 2 Lively
    [0.5, 1, 2, 3, 5]    // 3 Wild
]

/// Wander-interval presets (minSeconds, maxSeconds): how long the cursor roams
/// during an active burst before an (optional) rest.
private let intervalPresets: [(Double, Double)] = [
    (10, 20), (20, 40), (30, 60), (60, 120)
]

/// Central coordinator: owns every subsystem, enforces the permission gate, and
/// exposes the menu actions. Lives for the whole app lifetime.
final class AppController: NSObject, NSApplicationDelegate {

    private let settings = Settings.shared
    private let syntheticLog = SyntheticInputLog()
    private let autoPause = AutoPause()
    private let powerAssertion = PowerAssertion()
    private lazy var inputEngine = InputEngine(log: syntheticLog)
    private lazy var killSwitch = KillSwitch(tripleEscWindow: settings.tripleEscWindowSeconds,
                                             syntheticLog: syntheticLog)
    private lazy var stateMachine = StateMachine(settings: settings, input: inputEngine, autoPause: autoPause)
    private let menu = MenuBarController()
    private lazy var zoneEditor = ZoneEditorController(settings: settings)

    private let networkTrigger = NetworkTrigger()

    private var permissionPoll: Timer?
    private var safetyWatchdog: Timer?
    private var signalSources: [DispatchSourceSignal] = []

    /// The running session was started by the Wi-Fi trigger, so leaving the network
    /// ends it. A session the user started by hand is never ended by the trigger.
    private var sessionStartedByTrigger = false
    /// Whether the trigger condition held at the last evaluation. The trigger acts on
    /// arriving, not on every check, so stopping by hand on a trigger network sticks.
    private var triggerMatched = false

    private var displayAsleep = false
    private var systemSleeping = false
    /// Why the last session ended, when it was not the user's own Stop.
    private var stopNote: String?
    private var launchAtLogin = SMAppService.mainApp.status == .enabled

    /// How long posted motion may go unseen by our own tap before we stop.
    private let deafTapSeconds: TimeInterval = 3

    // MARK: - App lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        menu.install(controller: self)

        installSignalHandlers()
        observePower()
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(showMenuRequested),
            name: SingleInstance.showMenuNotification, object: nil)

        killSwitch.onTripleEsc = { [weak self] in
            self?.zoneEditor.close()   // the overlay must never outlive the stop gesture
            self?.turnOff()
        }
        killSwitch.onRealInput = { [weak self] in self?.autoPause.markActivity() }
        stateMachine.onStateChange = { [weak self] in self?.refreshUI() }
        stateMachine.onActivityPulse = { [weak self] in self?.powerAssertion.declareUserActivity() }
        zoneEditor.onClose = { [weak self] in
            self?.stateMachine.uiHold = false   // resume motion after the editor closes
            self?.refreshUI()
        }

        // Register the cursorplus:// URL handler so PHB (and any other
        // automation tool) can fire `open cursorplus://start` and
        // `open cursorplus://stop` to flip the bot without a menu click.
        // The triple-ESC kill switch and Auto-Pause-on-real-input semantics
        // still gate motion - URL commands cannot bypass those.
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )

        // First-run: ask for the grants. Then arm (or poll until granted).
        if !Permissions.allReady {
            Permissions.requestAll()
        }
        armIfPossible()
        if !Permissions.allReady { startPermissionPoll() }

        networkTrigger.onChange = { [weak self] in self?.evaluateTrigger() }
        networkTrigger.start()
        // Prompt once if never asked. A refusal is left alone here, or every login
        // would throw System Settings in the user's face; the submenu offers it.
        if settings.networkTriggerEnabled && !networkTrigger.locationAuthorized && !networkTrigger.locationDenied {
            networkTrigger.requestLocationAccess()
        }

        refreshUI()
    }

    /// Opening the app again while it runs (Finder, Spotlight, `open`) shows the menu,
    /// so it stays reachable even when the menu-bar icon is hidden by the notch.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMenuRequested()
        return false
    }

    /// A second copy that just bowed out asks us to show ourselves.
    @objc private func showMenuRequested() {
        DispatchQueue.main.async { [weak self] in
            NSApp.activate(ignoringOtherApps: true)
            self?.menu.popUpAtMouse()
        }
    }

    /// `kill`, Ctrl-C on `swift run`, and a logout all arrive as signals. Route them
    /// through a normal terminate so a held click is released and the tap removed,
    /// instead of the process vanishing mid-gesture.
    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            signalSources.append(source)
        }
    }

    /// Handle a `cursorplus://<command>` URL fired via NSWorkspace / `open`.
    ///
    /// Supported commands:
    ///   - `cursorplus://start`  - turn the bot on (idempotent)
    ///   - `cursorplus://stop`   - turn the bot off (idempotent)
    ///   - `cursorplus://toggle` - flip current state
    ///   - `cursorplus://quit`   - quit the app (for when the menu can't be reached)
    ///
    /// Unknown commands are logged and ignored. The triple-ESC kill switch
    /// + Auto-Pause semantics still apply; a URL `start` against a denied
    /// Accessibility grant cannot bypass `Permissions.allReady`.
    @objc func handleURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: urlString),
              url.scheme?.lowercased() == "cursorplus" else { return }
        let command = (url.host ?? "").lowercased()
        switch command {
        case "start":
            turnOn()
        case "stop":
            turnOff()
        case "toggle":
            toggleRunning()
        case "quit":
            quit()
        default:
            NSLog("Cursor+: ignoring unknown URL command '\(command)' from \(urlString)")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        zoneEditor.close()
        stopSafetyWatchdog()
        stateMachine.stop()
        killSwitch.stop()
        powerAssertion.end()
    }

    // MARK: - Arming / permissions

    /// Arm the global kill-switch tap as soon as Input Monitoring is granted, so
    /// the stop gesture is live even before the user starts the bot. Returns
    /// whether the kill switch is actually armed afterward.
    @discardableResult
    private func armIfPossible() -> Bool {
        if !killSwitch.isArmed { _ = killSwitch.start() }
        return killSwitch.isArmed
    }

    /// Secure Event Input (password fields, lock window, some terminals) silently
    /// blinds the key tap, so we cannot guarantee the kill switch — treat it as a
    /// reason to freeze motion.
    private var secureInputActive: Bool { IsSecureEventInputEnabled() }

    /// Can we safely allow motion right now? Only if the kill switch is live and
    /// Secure Input is not blinding it.
    private var safeToRun: Bool { killSwitch.isArmed && !secureInputActive }

    private func startPermissionPoll() {
        permissionPoll?.invalidate()
        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.armIfPossible()
            self.refreshUI()
            if Permissions.allReady {
                self.permissionPoll?.invalidate()
                self.permissionPoll = nil
                self.triggerMatched = false   // a trigger that fired before the grant gets another go
                self.evaluateTrigger()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        permissionPoll = timer
    }

    // MARK: - On/off

    private func turnOn(byTrigger: Bool = false) {
        guard Permissions.allReady else {
            Permissions.requestAll()
            Permissions.openAccessibilitySettings()
            startPermissionPoll()
            refreshUI()
            return
        }
        // HARD precondition: never move the cursor unless the kill switch is armed.
        guard armIfPossible() else {
            refreshUI()   // status will show "kill switch unavailable"
            return
        }
        reconcilePowerAssertion(running: true)
        stateMachine.safetyHold = !safeToRun
        stateMachine.uiHold = zoneEditor.isOpen   // never start frozen by a stale UI hold
        stateMachine.sleepHold = displayAsleep || systemSleeping
        stopNote = nil
        sessionStartedByTrigger = byTrigger
        stateMachine.start()
        startSafetyWatchdog()
        refreshUI()
    }

    /// Keep the live display-sleep assertion in sync with the setting + run state.
    private func reconcilePowerAssertion(running: Bool) {
        if running && settings.preventDisplaySleep {
            powerAssertion.begin()
        } else {
            powerAssertion.end()
        }
    }

    /// `note` says why, when it wasn't the user's own Stop; the menu shows it until
    /// the next start.
    private func turnOff(note: String? = nil) {
        stateMachine.stop()
        stopSafetyWatchdog()
        stateMachine.safetyHold = false
        powerAssertion.end()
        sessionStartedByTrigger = false
        stopNote = note
        refreshUI()
    }

    /// While running, continuously re-verify the kill switch is live and Secure
    /// Input isn't active; freeze motion (safetyHold) whenever it isn't safe, and
    /// keep trying to re-arm the tap.
    private func startSafetyWatchdog() {
        safetyWatchdog?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self, self.stateMachine.isOn else { return }
            // Fail safe to OFF, not to a hold: with the grant gone or the tap deaf,
            // neither auto-pause nor the Esc stop can see the user, so nothing would
            // ever release a hold and the cursor is no longer the user's to take back.
            if !Permissions.allReady {
                self.turnOff(note: "Accessibility permission lost")
                self.startPermissionPoll()
                return
            }
            if self.syntheticLog.tapLooksDeaf(after: self.deafTapSeconds) {
                self.killSwitch.reinstall()
                self.turnOff(note: "input monitoring stopped responding")
                return
            }
            if !self.killSwitch.isArmed { _ = self.killSwitch.start() }
            let hold = !self.safeToRun
            if self.stateMachine.safetyHold != hold {
                self.stateMachine.safetyHold = hold
                self.refreshUI()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        safetyWatchdog = timer
    }

    private func stopSafetyWatchdog() {
        safetyWatchdog?.invalidate()
        safetyWatchdog = nil
    }

    // MARK: - Menu actions

    @objc func toggleRunning() {
        if stateMachine.isOn { turnOff() } else { turnOn() }
    }

    @objc func setSpeedPreset(_ sender: NSMenuItem) {
        let tag = sender.tag
        guard speedPresets.indices.contains(tag) else { return }
        let w = speedPresets[tag]
        settings.setWeight(w[0], for: .verySlow)
        settings.setWeight(w[1], for: .slow)
        settings.setWeight(w[2], for: .normal)
        settings.setWeight(w[3], for: .fast)
        settings.setWeight(w[4], for: .veryFast)
        refreshUI()
    }

    @objc func setIntervalPreset(_ sender: NSMenuItem) {
        let tag = sender.tag
        guard intervalPresets.indices.contains(tag) else { return }
        settings.burstMinSeconds = intervalPresets[tag].0
        settings.burstMaxSeconds = intervalPresets[tag].1
        refreshUI()
    }

    @objc func togglePreventSleep() {
        settings.preventDisplaySleep.toggle()
        reconcilePowerAssertion(running: stateMachine.isOn)
        refreshUI()
    }

    @objc func toggleScrolling() {
        settings.scrollEnabled.toggle()
        refreshUI()
    }

    @objc func toggleIdlePauses() {
        settings.idlePausesEnabled.toggle()
        refreshUI()
    }

    @objc func toggleLongPauses() {
        settings.longPausesEnabled.toggle()
        refreshUI()
    }

    @objc func toggleClickZones() {
        settings.clickZonesEnabled.toggle()
        refreshUI()
    }

    @objc func editClickAreas() {
        openZoneEditor(.click)
    }

    @objc func clearClickAreas() {
        settings.saveClickZones([])
        refreshUI()
    }

    @objc func toggleAvoidZones() {
        settings.avoidZonesEnabled.toggle()
        refreshUI()
    }

    @objc func editAvoidAreas() {
        openZoneEditor(.avoid)
    }

    @objc func clearAvoidAreas() {
        settings.saveAvoidZones([])
        refreshUI()
    }

    /// Both editors are the same overlay; Tab switches between them from inside it.
    private func openZoneEditor(_ kind: ZoneKind) {
        stateMachine.uiHold = true   // freeze motion so the bot doesn't fight the user
        refreshUI()
        zoneEditor.open(kind)
    }

    @objc func openAccessibilitySettings() {
        Permissions.openAccessibilitySettings()
    }

    @objc func resetDefaults() {
        setSpeedPreset(menuItem(tag: 1))     // Balanced
        setIntervalPreset(menuItem(tag: 0))  // 10–20s
        settings.preventDisplaySleep = true
        settings.scrollEnabled = true
        settings.idlePausesEnabled = true
        settings.longPausesEnabled = false
        settings.clickZonesEnabled = true
        settings.avoidZonesEnabled = true
        reconcilePowerAssertion(running: stateMachine.isOn)
        refreshUI()
    }

    @objc func toggleSleepWhenDisplayOff() {
        settings.sleepWhenDisplayOff.toggle()
        refreshUI()
    }

    @objc func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            NSLog("Cursor+: login item change failed: \(error)")
        }
        if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        launchAtLogin = service.status == .enabled
        refreshUI()
    }

    // MARK: - Wi-Fi trigger

    @objc func toggleNetworkTrigger() {
        settings.networkTriggerEnabled.toggle()
        if settings.networkTriggerEnabled && !networkTrigger.locationAuthorized {
            networkTrigger.requestLocationAccess()
        }
        evaluateTrigger()
    }

    @objc func addCurrentNetwork() {
        guard let ssid = networkTrigger.currentSSID else { return }
        if !settings.triggerSSIDs.contains(ssid) { settings.triggerSSIDs.append(ssid) }
        settings.networkTriggerEnabled = true   // adding a network means "use it"
        evaluateTrigger()
    }

    @objc func removeTriggerNetwork(_ sender: NSMenuItem) {
        guard let ssid = sender.representedObject as? String else { return }
        settings.triggerSSIDs.removeAll { $0 == ssid }
        evaluateTrigger()
    }

    @objc func requestLocationAccess() {
        networkTrigger.requestLocationAccess()
    }

    /// Called as the trigger submenu opens, so it shows the network you are on now.
    func refreshNetwork() {
        networkTrigger.refresh()
        refreshUI()
    }

    private var triggerConditionMet: Bool {
        guard settings.networkTriggerEnabled, let ssid = networkTrigger.currentSSID else { return false }
        return settings.triggerSSIDs.contains(ssid)
    }

    /// Start a session on arriving at a trigger network; end the trigger's own
    /// session once the condition no longer holds (left the network, the network was
    /// removed, or the trigger was switched off).
    private func evaluateTrigger() {
        let matched = triggerConditionMet
        let arrived = matched && !triggerMatched
        triggerMatched = matched
        if arrived && !stateMachine.isOn && !displayAsleep && !systemSleeping {
            turnOn(byTrigger: true)
        } else if !matched && stateMachine.isOn && sessionStartedByTrigger {
            turnOff(note: "left the trigger Wi-Fi")
        }
        refreshUI()
    }

    // MARK: - Display and system sleep

    private func observePower() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(screensDidSleep),
                       name: NSWorkspace.screensDidSleepNotification, object: nil)
        nc.addObserver(self, selector: #selector(screensDidWake),
                       name: NSWorkspace.screensDidWakeNotification, object: nil)
        nc.addObserver(self, selector: #selector(systemWillSleep),
                       name: NSWorkspace.willSleepNotification, object: nil)
        nc.addObserver(self, selector: #selector(systemDidWake),
                       name: NSWorkspace.didWakeNotification, object: nil)
    }

    /// Display off: hold all motion either way, since a posted move would light the
    /// screen straight back up. With the setting on, end the session and sleep the
    /// Mac rather than keep it awake in the dark.
    @objc private func screensDidSleep(_ note: Notification) {
        displayAsleep = true
        syncSleepHold()
        guard stateMachine.isOn, settings.sleepWhenDisplayOff else { return }
        turnOff(note: "display turned off")
        // A beat for the stop to settle (released click, dropped assertion).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self, self.displayAsleep else { return }   // woke meanwhile
            Self.sleepSystemNow()
        }
    }

    @objc private func screensDidWake(_ note: Notification) {
        displayAsleep = false
        syncSleepHold()
        // Coming back counts as arriving again, so a trigger session that the display
        // ended picks up once you are back on a trigger network.
        triggerMatched = false
        networkTrigger.refresh()
        evaluateTrigger()
    }

    @objc private func systemWillSleep(_ note: Notification) {
        systemSleeping = true
        syncSleepHold()
    }

    @objc private func systemDidWake(_ note: Notification) {
        systemSleeping = false
        syncSleepHold()
        armIfPossible()   // the tap can come back from sleep disabled
    }

    private func syncSleepHold() {
        stateMachine.sleepHold = displayAsleep || systemSleeping
        refreshUI()
    }

    /// Ask for system sleep. The console user may do this without admin rights;
    /// `pmset sleepnow` is the fallback if the IOKit route is refused.
    private static func sleepSystemNow() {
        let port = IOPMFindPowerManagement(mach_port_t(MACH_PORT_NULL))
        if port != 0 {
            let result = IOPMSleepSystem(port)
            IOServiceClose(port)
            if result == kIOReturnSuccess { return }
        }
        let pmset = Process()
        pmset.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        pmset.arguments = ["sleepnow"]
        try? pmset.run()
    }

    @objc func quit() {
        zoneEditor.close()
        turnOff()
        killSwitch.stop()
        NSApp.terminate(nil)
    }

    private func menuItem(tag: Int) -> NSMenuItem {
        let item = NSMenuItem()
        item.tag = tag
        return item
    }

    // MARK: - UI

    private func currentSpeedPresetTag() -> Int {
        let w = settings.speedWeights()
        let current: [Double] = [w[.verySlow] ?? 0, w[.slow] ?? 0, w[.normal] ?? 0, w[.fast] ?? 0, w[.veryFast] ?? 0]
        return speedPresets.firstIndex { preset in
            zip(preset, current).allSatisfy { abs($0 - $1) < 0.0001 }
        } ?? -1
    }

    private func currentIntervalPresetTag() -> Int {
        intervalPresets.firstIndex {
            abs($0.0 - settings.burstMinSeconds) < 0.0001 && abs($0.1 - settings.burstMaxSeconds) < 0.0001
        } ?? -1
    }

    private func refreshUI() {
        let ready = Permissions.allReady
        let armed = killSwitch.isArmed
        let secure = secureInputActive
        let running = stateMachine.isOn
        let paused = stateMachine.isPaused
        let resting = stateMachine.isResting

        let status: String
        if !ready {
            status = "Cursor+: needs permission"
        } else if !armed {
            status = "Cursor+: kill switch unavailable"
        } else if running && (displayAsleep || systemSleeping) {
            status = "Cursor+: paused (display off)"
        } else if running && secure {
            status = "Cursor+: paused (secure input)"
        } else if running && paused {
            status = "Cursor+: paused (you're active)"
        } else if running && resting {
            status = "Cursor+: ON · resting"
        } else if running {
            status = "Cursor+: ON · keeping active"
        } else if let note = stopNote {
            status = "Cursor+: off · \(note)"
        } else {
            status = "Cursor+: off"
        }

        menu.refresh(MenuState(
            statusText: status,
            toggleTitle: running ? "Stop" : "Start",
            running: running,
            paused: paused,
            ready: ready,
            killSwitchArmed: armed,
            preventSleep: settings.preventDisplaySleep,
            sleepWhenDisplayOff: settings.sleepWhenDisplayOff,
            launchAtLogin: launchAtLogin,
            triggerEnabled: settings.networkTriggerEnabled,
            triggerSSIDs: settings.triggerSSIDs,
            currentSSID: networkTrigger.currentSSID,
            locationAuthorized: networkTrigger.locationAuthorized,
            scrollEnabled: settings.scrollEnabled,
            idlePausesEnabled: settings.idlePausesEnabled,
            longPausesEnabled: settings.longPausesEnabled,
            clickZonesEnabled: settings.clickZonesEnabled,
            clickZoneCount: settings.loadClickZones().count,
            avoidZonesEnabled: settings.avoidZonesEnabled,
            avoidZoneCount: settings.loadAvoidZones().count,
            speedPresetTag: currentSpeedPresetTag(),
            intervalPresetTag: currentIntervalPresetTag()
        ))
    }
}
