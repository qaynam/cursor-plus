import AppKit

/// Snapshot of everything the menu needs to render.
struct MenuState {
    let statusText: String
    let toggleTitle: String
    let running: Bool
    let paused: Bool
    let ready: Bool
    let killSwitchArmed: Bool
    let preventSleep: Bool
    let sleepWhenDisplayOff: Bool
    let launchAtLogin: Bool
    let triggerEnabled: Bool
    let triggerSSIDs: [String]
    let currentSSID: String?
    let locationAuthorized: Bool
    let scrollEnabled: Bool
    let idlePausesEnabled: Bool
    let longPausesEnabled: Bool
    let clickZonesEnabled: Bool
    let clickZoneCount: Int
    let avoidZonesEnabled: Bool
    let avoidZoneCount: Int
    let speedPresetTag: Int      // -1 = custom
    let intervalPresetTag: Int   // -1 = custom
    let idleDelayPresetTag: Int  // -1 = custom
}

/// Owns the menu-bar `NSStatusItem` and its menu. Menu items target the
/// `AppController` (an NSObject) via selectors — the standard AppKit pattern.
///
/// Laid out along the macOS menu guidelines: the live status and the one action
/// people open the menu for (Start/Stop) come first; settings are grouped under
/// section headers; rarely used sets (area editing, the Wi-Fi list) sit one submenu
/// down and never deeper; titles use title-style capitalization, with an ellipsis
/// only where a further step follows; and every actionable item carries an SF
/// Symbol, so a group reads at a glance and its titles line up.
final class MenuBarController: NSObject, NSMenuDelegate {

    private var statusItem: NSStatusItem!
    private weak var controller: AppController?

    private var statusLine: NSMenuItem!
    private var toggleItem: NSMenuItem!
    private var stopHintItem: NSMenuItem!

    private var speedItems: [NSMenuItem] = []
    private var intervalItems: [NSMenuItem] = []
    private var scrollItem: NSMenuItem!
    private var idlePausesItem: NSMenuItem!
    private var longPausesItem: NSMenuItem!

    private var clickToggleItem: NSMenuItem!
    private var editClickItem: NSMenuItem!
    private var clearClickItem: NSMenuItem!
    private var avoidToggleItem: NSMenuItem!
    private var editAvoidItem: NSMenuItem!
    private var clearAvoidItem: NSMenuItem!

    private var preventSleepItem: NSMenuItem!
    private var sleepOnDisplayOffItem: NSMenuItem!

    private var idleDelayItems: [NSMenuItem] = []
    private var triggerParent: NSMenuItem!
    private var triggerMenu: NSMenu!
    private var launchAtLoginItem: NSMenuItem!

    private var lastState: MenuState?

    static let speedPresetNames = ["Calm", "Balanced", "Lively", "Wild"]
    static let intervalPresetNames = ["10–20s", "20–40s", "30–60s", "60–120s"]
    static let idleDelayPresetNames = ["3 Seconds", "1 Minute", "2 Minutes", "5 Minutes",
                                       "10 Minutes", "15 Minutes", "30 Minutes"]

    /// One gauge per speed preset, filling up from Calm to Wild.
    private static let speedPresetSymbols = ["gauge.with.dots.needle.0percent",
                                             "gauge.with.dots.needle.33percent",
                                             "gauge.with.dots.needle.67percent",
                                             "gauge.with.dots.needle.100percent"]

    // The most human-like / least-detectable option in each submenu — the one to
    // leave selected the majority of the time. Marked "Recommended" in the menu.
    // Balanced = natural speed spread centered on normal; 10–20s = frequent, human
    // burst/pause rhythm (longer bursts move continuously too long to look human).
    private static let recommendedSpeedIndex = 1     // Balanced
    private static let recommendedIntervalIndex = 0  // 10–20s

    func install(controller: AppController) {
        self.controller = controller

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "cursorarrow",
                                           accessibilityDescription: "Cursor+")

        let menu = NSMenu()
        menu.autoenablesItems = false

        // Status and the main action.
        statusLine = infoItem("Cursor+", symbol: "cursorarrow")
        menu.addItem(statusLine)
        menu.addItem(.separator())
        toggleItem = makeItem("Start", symbol: "play.fill", #selector(AppController.toggleRunning))
        menu.addItem(toggleItem)
        stopHintItem = infoItem("Press Esc three times to stop", symbol: "escape")
        menu.addItem(stopHintItem)

        addSection("Motion", to: menu)
        speedItems = presetItems(Self.speedPresetNames, symbols: Self.speedPresetSymbols,
                                 recommended: Self.recommendedSpeedIndex,
                                 #selector(AppController.setSpeedPreset(_:)))
        menu.addItem(submenuItem("Motion Speed", symbol: "speedometer", items: speedItems))
        intervalItems = presetItems(Self.intervalPresetNames,
                                    recommended: Self.recommendedIntervalIndex,
                                    #selector(AppController.setIntervalPreset(_:)))
        menu.addItem(submenuItem("Wander Interval", symbol: "timer", items: intervalItems))
        scrollItem = makeItem("Occasional Scrolling", symbol: "arrow.up.and.down",
                              #selector(AppController.toggleScrolling))
        menu.addItem(scrollItem)
        idlePausesItem = makeItem("Human Idle Pauses", symbol: "pause",
                                  #selector(AppController.toggleIdlePauses))
        menu.addItem(idlePausesItem)
        longPausesItem = makeItem("Occasional Long Pauses", symbol: "hourglass",
                                  #selector(AppController.toggleLongPauses))
        menu.addItem(longPausesItem)

        // Areas: drawn once, revisited rarely, so each kind gets one submenu.
        addSection("Areas", to: menu)
        clickToggleItem = makeItem("Click Inside Click Areas", symbol: "cursorarrow.click",
                                   #selector(AppController.toggleClickZones))
        editClickItem = makeItem("Edit Click Areas…", symbol: "pencil",
                                 #selector(AppController.editClickAreas))
        clearClickItem = makeItem("Remove All Click Areas", symbol: "trash",
                                  #selector(AppController.clearClickAreas))
        menu.addItem(submenuItem("Click Areas", symbol: "cursorarrow.click.2",
                                 items: [clickToggleItem, editClickItem, .separator(), clearClickItem]))
        avoidToggleItem = makeItem("Keep Out of Avoid Areas", symbol: "hand.raised",
                                   #selector(AppController.toggleAvoidZones))
        editAvoidItem = makeItem("Edit Avoid Areas…", symbol: "pencil",
                                 #selector(AppController.editAvoidAreas))
        clearAvoidItem = makeItem("Remove All Avoid Areas", symbol: "trash",
                                  #selector(AppController.clearAvoidAreas))
        menu.addItem(submenuItem("Avoid Areas", symbol: "nosign",
                                 items: [avoidToggleItem, editAvoidItem, .separator(), clearAvoidItem]))

        addSection("Display & Sleep", to: menu)
        preventSleepItem = makeItem("Prevent Display Sleep", symbol: "display",
                                    #selector(AppController.togglePreventSleep))
        menu.addItem(preventSleepItem)
        sleepOnDisplayOffItem = makeItem("Sleep Mac When Display Turns Off", symbol: "moon.zzz",
                                         #selector(AppController.toggleSleepWhenDisplayOff))
        menu.addItem(sleepOnDisplayOffItem)

        addSection("Automation", to: menu)
        idleDelayItems = presetItems(Self.idleDelayPresetNames,
                                     #selector(AppController.setIdleDelayPreset(_:)))
        menu.addItem(submenuItem("Start After Idle", symbol: "clock", items: idleDelayItems,
                                 header: "Move once you've been idle for"))
        // Rebuilt each time it opens, since the saved list and the current network
        // both change underneath it.
        triggerMenu = NSMenu()
        triggerMenu.autoenablesItems = false
        triggerMenu.delegate = self
        triggerParent = NSMenuItem(title: "Auto-Start on Wi-Fi", action: nil, keyEquivalent: "")
        triggerParent.image = Self.symbol("wifi")
        triggerParent.submenu = triggerMenu
        menu.addItem(triggerParent)
        launchAtLoginItem = makeItem("Open at Login", symbol: "person.crop.circle",
                                     #selector(AppController.toggleLaunchAtLogin))
        menu.addItem(launchAtLoginItem)

        menu.addItem(.separator())
        menu.addItem(makeItem("Open Accessibility Settings…", symbol: "lock.shield",
                              #selector(AppController.openAccessibilitySettings)))
        menu.addItem(makeItem("Reset to Defaults", symbol: "arrow.counterclockwise",
                              #selector(AppController.resetDefaults)))

        menu.addItem(.separator())
        menu.addItem(makeItem("Quit Cursor+", symbol: "power", #selector(AppController.quit), key: "q"))

        statusItem.menu = menu
    }

    /// Show the menu at the mouse. For when the status item can't be clicked: hidden
    /// behind the notch, or a crowded menu bar.
    func popUpAtMouse() {
        statusItem.menu?.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    func refresh(_ state: MenuState) {
        lastState = state
        let stateSymbol = Self.stateSymbol(state)

        statusLine.title = state.statusText
        statusLine.image = Self.symbol(stateSymbol)

        toggleItem.title = state.toggleTitle
        toggleItem.image = Self.symbol(state.running ? "stop.fill" : "play.fill")
        // Only allow starting when the kill switch is actually live (or to stop).
        toggleItem.isEnabled = state.running || (state.ready && state.killSwitchArmed)

        stopHintItem.title = state.killSwitchArmed
            ? "Press Esc three times to stop"
            : "Stop gesture inactive: check Accessibility"
        stopHintItem.image = Self.symbol(state.killSwitchArmed ? "escape" : "exclamationmark.triangle")

        Self.check(speedItems, selected: state.speedPresetTag)
        Self.check(intervalItems, selected: state.intervalPresetTag)
        scrollItem.state = state.scrollEnabled ? .on : .off
        idlePausesItem.state = state.idlePausesEnabled ? .on : .off
        longPausesItem.state = state.longPausesEnabled ? .on : .off

        refreshAreaItems(toggle: clickToggleItem, edit: editClickItem, clear: clearClickItem,
                         enabled: state.clickZonesEnabled, count: state.clickZoneCount,
                         noun: "Click Area")
        refreshAreaItems(toggle: avoidToggleItem, edit: editAvoidItem, clear: clearAvoidItem,
                         enabled: state.avoidZonesEnabled, count: state.avoidZoneCount,
                         noun: "Avoid Area")

        preventSleepItem.state = state.preventSleep ? .on : .off
        sleepOnDisplayOffItem.state = state.sleepWhenDisplayOff ? .on : .off

        Self.check(idleDelayItems, selected: state.idleDelayPresetTag)
        triggerParent.state = state.triggerEnabled ? .on : .off
        launchAtLoginItem.state = state.launchAtLogin ? .on : .off

        statusItem.button?.image = NSImage(systemSymbolName: stateSymbol,
                                           accessibilityDescription: "Cursor+")
    }

    /// The toggle does nothing with no areas drawn, and Edit becomes Add.
    private func refreshAreaItems(toggle: NSMenuItem, edit: NSMenuItem, clear: NSMenuItem,
                                  enabled: Bool, count: Int, noun: String) {
        toggle.state = enabled ? .on : .off
        toggle.isEnabled = count > 0
        edit.title = count > 0 ? "Edit \(noun)s (\(count))…" : "Add a \(noun)…"
        edit.image = Self.symbol(count > 0 ? "pencil" : "plus")
        clear.isEnabled = count > 0
    }

    // MARK: - Wi-Fi trigger submenu

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === triggerMenu else { return }
        controller?.refreshNetwork()   // re-reads the SSID and pushes a fresh state
        guard let state = lastState else { return }
        menu.removeAllItems()

        let enable = makeItem("Start on Saved Networks", symbol: "wifi",
                              #selector(AppController.toggleNetworkTrigger))
        enable.state = state.triggerEnabled ? .on : .off
        menu.addItem(enable)

        addSection("Current Network", to: menu)
        if !state.locationAuthorized {
            menu.addItem(infoItem("Wi-Fi name needs Location access", symbol: "location.slash"))
            menu.addItem(makeItem("Allow Location Access…", symbol: "location",
                                  #selector(AppController.requestLocationAccess)))
        } else if let ssid = state.currentSSID {
            menu.addItem(infoItem(ssid, symbol: "wifi"))
            let saved = state.triggerSSIDs.contains(ssid)
            let add = makeItem(saved ? "Already Saved" : "Add to Saved Networks",
                               symbol: saved ? "checkmark.circle" : "plus.circle",
                               #selector(AppController.addCurrentNetwork))
            add.isEnabled = !saved
            menu.addItem(add)
        } else {
            menu.addItem(infoItem("Not on Wi-Fi", symbol: "wifi.slash"))
        }

        addSection("Saved Networks", to: menu)
        if state.triggerSSIDs.isEmpty {
            menu.addItem(infoItem("None", symbol: "tray"))
        }
        for ssid in state.triggerSSIDs {
            let it = makeItem("Remove “\(ssid)”", symbol: "minus.circle",
                              #selector(AppController.removeTriggerNetwork(_:)))
            it.representedObject = ssid
            menu.addItem(it)
        }
    }

    // MARK: - Building blocks

    /// An item that sends `action` to the controller.
    private func makeItem(_ title: String, symbol: String?, _ action: Selector, key: String = "") -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
        it.target = controller
        it.image = symbol.flatMap(Self.symbol)
        return it
    }

    /// A line of information: status, a hint, the network you're on.
    private func infoItem(_ title: String, symbol: String?) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        it.image = symbol.flatMap(Self.symbol)
        it.isEnabled = false
        return it
    }

    private func submenuItem(_ title: String, symbol: String, items: [NSMenuItem],
                             header: String? = nil) -> NSMenuItem {
        let sub = NSMenu()
        sub.autoenablesItems = false
        if let header { sub.addItem(.sectionHeader(title: header)) }
        for item in items { sub.addItem(item) }
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        parent.image = Self.symbol(symbol)
        parent.submenu = sub
        return parent
    }

    /// One checkable item per preset; the tag is the preset index.
    private func presetItems(_ names: [String], symbols: [String]? = nil, recommended: Int? = nil,
                             _ action: Selector) -> [NSMenuItem] {
        names.enumerated().map { i, name in
            let it = makeItem(name, symbol: symbols?[i], action)
            it.tag = i
            if i == recommended { Self.markRecommended(it) }
            return it
        }
    }

    private func addSection(_ title: String, to menu: NSMenu) {
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: title))
    }

    private static func markRecommended(_ item: NSMenuItem) {
        if #available(macOS 14.4, *) {
            item.subtitle = "Recommended"
        } else {
            item.title += "  ★"
        }
    }

    private static func check(_ items: [NSMenuItem], selected: Int) {
        for (i, item) in items.enumerated() { item.state = (i == selected) ? .on : .off }
    }

    private static func stateSymbol(_ state: MenuState) -> String {
        if !state.ready { return "exclamationmark.triangle" }
        if state.paused { return "pause.circle" }
        if state.running { return "cursorarrow.motionlines" }
        return "cursorarrow"
    }

    /// Menu icons are decorative (the title says it all), so no accessibility label.
    /// Cached: the menu refreshes on every state change.
    private static var symbolCache: [String: NSImage] = [:]

    private static func symbol(_ name: String) -> NSImage? {
        if let cached = symbolCache[name] { return cached }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        symbolCache[name] = image
        return image
    }
}
