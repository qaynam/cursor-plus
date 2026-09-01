import Foundation
import CoreGraphics

/// The activity rhythm. Drives, on the main run loop, a human-like loop:
///
///   MOVING (wander to random destinations for an "active burst") ->
///   optionally SCROLLING (an occasional deliberate scroll) ->
///   optionally a CLICK VISIT (curve to a user-defined click zone, dwell, click) ->
///   optionally RESTING (a short, bounded pause, like a human reading) ->
///   MOVING ...
///
/// If the user marked any no-go areas, every destination is chosen outside them and
/// every path is routed around them (see AvoidZones). With none defined, or with the
/// setting off, all of that short-circuits on an empty array and the loop below is
/// exactly what it was before.
///
/// Clicking happens ONLY inside user-defined zones (see ZoneRect) — never on
/// arbitrary/empty space — so it is goal-directed (the human pattern) rather than
/// the timer-on-empty-desktop clicking that was previously removed. With no zones
/// defined (or clicking disabled) the loop is movement + scroll only. Motion comes
/// in bursts separated by short rests — still resetting the idle timer often enough
/// (and with the IOPMAssertion) to keep the Mac active.
///
/// It honors auto-pause every tick (pausing the instant the real user is active).
///
/// Threading: everything here runs on the main thread (the self-rescheduling tick
/// targets `.main` and the event tap delivers on the main run loop), so no locking
/// is required.
final class StateMachine {

    enum Phase {
        case idle             // tool is OFF
        case moving           // wandering during an active burst
        case scrolling        // emitting an occasional deliberate scroll
        case approachingClick // moving toward a point inside a user click zone
        case clickDwell       // brief human pause on the target before clicking
        case clicking         // left button held down for a human 50–150ms
        case resting          // a short, bounded human-like pause
    }

    // Collaborators
    private let settings: Settings
    private let input: InputEngine
    private let autoPause: AutoPause

    // Observability
    var onStateChange: (() -> Void)?
    /// Fired at the start of each active burst, so the owner can pulse an idle-reset
    /// backstop (IOPMAssertionDeclareUserActivity) in addition to the HID motion.
    var onActivityPulse: (() -> Void)?

    // Public state
    private(set) var isOn = false
    private(set) var isPaused = false
    private(set) var phase: Phase = .idle
    var isResting: Bool { phase == .resting }

    /// Set by AppController to freeze motion when it cannot guarantee the kill
    /// switch (tap not armed, or Secure Input active). Honored like a pause.
    var safetyHold = false

    /// Set by AppController to freeze motion while a modal UI (the click-zone editor)
    /// is open, so the bot doesn't fight the user's mouse. Honored like a pause.
    var uiHold = false

    /// Longest a single sub-move may take, so one slow move can't run forever.
    private let maxMoveSeconds = 4.0

    /// Human pre-click dwell and button-hold ranges (seconds).
    private let clickDwellRange = 0.08...0.30
    private let clickHoldRange = 0.05...0.15

    /// How often to re-pulse the display-wake assertion during a long idle pause.
    private let longPauseRepulseSeconds: TimeInterval = 25

    // Self-rescheduling tick (~120 Hz nominal, with per-tick interval jitter so the
    // synthetic event stream isn't suspiciously uniform).
    private let baseTickSeconds = 1.0 / 120.0
    private var runToken = 0

    // Motion
    private var currentPoint: CGPoint = .zero
    private var player: PathPlayer?
    private var scrollPlayer: ScrollPlayer?
    private var scrollStarted = false
    private var lastTick: TimeInterval = 0

    // Burst / rest clocks
    private var burstStart: TimeInterval = 0
    private var burstDuration: TimeInterval = 0
    private var restStart: TimeInterval = 0
    private var restDuration: TimeInterval = 0
    private var lastRestPulse: TimeInterval = 0   // re-pulse the wake assertion during long pauses

    // No-go areas. `avoidRects` are the rectangles exactly as the user drew them (the
    // hard boundary); `avoidBlockers` are those grown by `avoidMargin`, the comfort
    // distance paths are actually planned around so motion keeps a natural berth
    // instead of shaving the edge. Refreshed once per move, never per tick: reading
    // them at 120 Hz would decode JSON for nothing, and a move lasts ≤4s anyway.
    private var avoidRects: [CGRect] = []
    private var avoidBlockers: [CGRect] = []
    private var avoidMargin: CGFloat = 0

    // Click-visit state
    private var clickPoint: CGPoint = .zero       // frozen press point (so down/up match)
    private var clickDwellStart: TimeInterval = 0
    private var clickDwellDuration: TimeInterval = 0
    private var clickHoldStart: TimeInterval = 0
    private var clickHoldDuration: TimeInterval = 0
    private var clickDown = false                 // is a synthetic button currently held?

    init(settings: Settings, input: InputEngine, autoPause: AutoPause) {
        self.settings = settings
        self.input = input
        self.autoPause = autoPause
    }

    private func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    // MARK: - On/off

    func start() {
        guard !isOn else { return }
        isOn = true
        isPaused = false
        autoPause.reset()
        input.reset()                                   // reseed deltas, clear stale log
        currentPoint = InputEngine.currentLocation()
        beginBurst()
        lastTick = now()

        runToken &+= 1
        scheduleNextTick(token: runToken)
        onStateChange?()
    }

    func stop() {
        guard isOn else { return }
        isOn = false
        isPaused = false
        releaseClickIfHeld()    // never leave a button held when stopping
        phase = .idle
        runToken &+= 1          // invalidate any in-flight scheduled tick
        player = nil
        scrollPlayer = nil
        scrollStarted = false
        avoidRects = []
        avoidBlockers = []
        input.reset()           // drop stale self-recognition entries
        onStateChange?()
    }

    // MARK: - Tick scheduling (jittered, self-rescheduling)

    private func scheduleNextTick(token: Int) {
        guard isOn, token == runToken else { return }
        let interval = baseTickSeconds * Double.random(in: 0.8...1.6)
        DispatchQueue.main.asyncAfter(deadline: .now() + interval) { [weak self] in
            self?.tick(token: token)
        }
    }

    private func tick(token: Int) {
        guard isOn, token == runToken else { return }
        let t = now()
        let dt = max(0, min(t - lastTick, 0.1))   // clamp after any stall
        lastTick = t
        step(t: t, dt: dt)
        scheduleNextTick(token: token)
    }

    // MARK: - Step

    private func step(t: TimeInterval, dt: TimeInterval) {
        // Pause instantly on real user input OR when the app cannot guarantee the
        // kill switch (safetyHold); resume only after a quiet cooldown.
        let userActive = autoPause.shouldPause(cooldown: settings.autoPauseCooldownSeconds)
        if userActive || safetyHold || uiHold {
            releaseClickIfHeld()            // never leave a button held across a pause
            if !isPaused { isPaused = true; onStateChange?() }
            return
        } else if isPaused {
            isPaused = false
            input.reset()                                  // reseed deltas, clear stale log
            currentPoint = InputEngine.currentLocation()   // user may have moved it
            beginBurst()                                   // fresh burst
            onStateChange?()
        }

        switch phase {
        case .idle:
            break

        case .moving:
            if player == nil && t - burstStart >= burstDuration {
                endBurst()
                return
            }
            if player == nil && !startWanderMove() { return }
            advance(dt: dt)

        case .scrolling:
            guard let sp = scrollPlayer else { beginInterludeOrBurst(); return }
            if let delta = sp.advance(by: dt), delta != 0 {
                input.scroll(deltaY: delta, phase: scrollStarted ? .changed : .began)
                scrollStarted = true
            }
            if sp.isFinished {
                if scrollStarted { input.scroll(deltaY: 0, phase: .ended) }   // close the gesture
                scrollPlayer = nil
                scrollStarted = false
                beginInterludeOrBurst()
            }

        case .approachingClick:
            if player == nil {           // arrived at the in-zone target
                phase = .clickDwell
                clickDwellStart = t
                clickDwellDuration = Double.random(in: clickDwellRange)   // human pre-click pause
                return
            }
            advance(dt: dt)

        case .clickDwell:
            if t - clickDwellStart >= clickDwellDuration { beginClick(at: t) }

        case .clicking:
            // Cursor frozen during the hold (no advance), so the press can't drag.
            if t - clickHoldStart >= clickHoldDuration {
                releaseClickIfHeld()
                beginInterludeOrBurst()
            }

        case .resting:
            // During a long pause no HID events post, so re-pulse the display-wake
            // assertion every ~25s to keep the screen awake while we sit idle.
            if t - lastRestPulse >= longPauseRepulseSeconds {
                lastRestPulse = t
                onActivityPulse?()
            }
            if t - restStart >= restDuration { beginBurst() }
        }
    }

    // MARK: - Phase transitions

    private func beginBurst() {
        phase = .moving
        player = nil
        scrollPlayer = nil
        burstStart = now()
        burstDuration = settings.randomBurstSeconds()
        onActivityPulse?()      // idle-reset backstop at the start of each burst
        onStateChange?()
    }

    /// End of an active burst: occasionally pay a goal-directed "click visit" to a
    /// user-defined zone, else occasionally scroll, else go to the interlude. The
    /// cheap probability checks short-circuit before decoding the zones.
    private func endBurst() {
        if settings.clickZonesEnabled && Double.random(in: 0..<1) < settings.clickProbability,
           let target = pickClickTarget() {
            beginClickVisit(target: target)
            return
        }
        if settings.scrollEnabled && Double.random(in: 0..<1) < settings.scrollProbability {
            phase = .scrolling
            scrollPlayer = ScrollPlayer()
            scrollStarted = false
            onActivityPulse?()      // idle-reset backstop while scrolling
            onStateChange?()
        } else {
            beginInterludeOrBurst()
        }
    }

    // MARK: - Click visit (goal-directed, user-defined zones only)

    /// A click point inside one of the user's click areas that also clears the no-go
    /// areas. Returns nil when every click area is covered by one, in which case the
    /// cycle simply skips the click rather than clicking where it was told not to.
    private func pickClickTarget() -> CGPoint? {
        refreshAvoidZones()
        let zones = settings.loadClickZones()
        guard !zones.isEmpty else { return nil }
        // Only the hard boundary applies to a target: the user is allowed to put a
        // click area right up against a no-go area, and `newPlayer` relaxes that one
        // area's comfort margin so the point stays reachable.
        let forbidden = AvoidZones.targetBlockers(from: avoidRects)
        for zone in zones.shuffled() {
            let z = ZoneRect(rect: zone)
            for _ in 0..<24 {
                let p = Geometry.clampToVisible(z.randomPoint())
                if !AvoidZones.contains(p, in: forbidden) { return p }
            }
        }
        return nil
    }

    /// Curve toward a vetted point inside a user click zone; on arrival we dwell then
    /// click. The approach reuses the normal WindMouse path (routed around any no-go
    /// areas), so it naturally curves in — exactly the human point-and-click pattern.
    private func beginClickVisit(target: CGPoint) {
        // Phase only flips once a move exists: `.approachingClick` with no player
        // means "arrived", and entering it without one would click wherever the
        // cursor happens to be sitting. `mustArrive` covers the other half of that:
        // a move that only gets partway is fine when wandering and never fine when
        // the point it stops at is where a click lands.
        guard newPlayer(to: target, mustArrive: true) else { beginInterludeOrBurst(); return }
        phase = .approachingClick
        onActivityPulse?()
        onStateChange?()
    }

    /// Press the left button at the (frozen) arrival point and hold a human 50–150ms.
    private func beginClick(at t: TimeInterval) {
        phase = .clicking
        clickPoint = currentPoint
        clickHoldStart = t
        clickHoldDuration = Double.random(in: clickHoldRange)
        input.mouseDown(at: Geometry.clampToVisible(clickPoint))
        clickDown = true
        onActivityPulse?()
        onStateChange?()
    }

    /// Release a held synthetic click immediately, at the SAME point as the press so
    /// it can never read as a drag. Idempotent; safe to call from any exit path.
    private func releaseClickIfHeld() {
        guard clickDown else { return }
        clickDown = false
        input.mouseUp(at: Geometry.clampToVisible(clickPoint))
    }

    /// After moving/scrolling: take a short human-like rest (if enabled) then move.
    /// Occasionally (opt-in) the rest is a genuinely long pause, giving the activity
    /// a human heavy-tailed idle distribution instead of "never idle >10s".
    private func beginInterludeOrBurst() {
        guard settings.idlePausesEnabled else { beginBurst(); return }
        phase = .resting
        restStart = now()
        lastRestPulse = restStart
        if settings.longPausesEnabled && Double.random(in: 0..<1) < settings.longPauseProbability {
            restDuration = settings.randomLongPauseSeconds()
        } else {
            restDuration = settings.randomRestSeconds()
        }
        onActivityPulse?()      // pulse at rest start
        onStateChange?()
    }

    // MARK: - No-go areas

    /// Re-read the user's no-go areas and re-roll the comfort margin. Called once at
    /// the top of each move, so an edit takes effect within one move and the clearance
    /// is never a constant a watcher could measure.
    private func refreshAvoidZones() {
        avoidRects = settings.avoidZonesEnabled ? settings.loadAvoidZones() : []
        avoidMargin = AvoidZones.randomMargin()
        avoidBlockers = AvoidZones.blockers(from: avoidRects, margin: avoidMargin)
    }

    /// Pick a reachable wander destination and start moving. False means the no-go
    /// areas left nowhere to go, and a short breather has been taken instead.
    private func startWanderMove() -> Bool {
        refreshAvoidZones()
        for _ in 0..<4 {
            guard let dest = Geometry.randomVisiblePointCG(avoiding: avoidBlockers) else { break }
            if newPlayer(to: dest) { return true }
        }
        beginBackoffRest()
        return false
    }

    /// Nowhere to move to — the no-go areas cover the reachable screen. Sit still for
    /// a beat rather than retrying at tick rate; the activity pulse keeps running, so
    /// the display still stays awake.
    private func beginBackoffRest() {
        phase = .resting
        restStart = now()
        lastRestPulse = restStart
        restDuration = Double.random(in: 1.0...2.0)
        onActivityPulse?()
        onStateChange?()
    }

    // MARK: - Motion helpers

    /// Build the move to `dest`, curving around any no-go areas on the way. False
    /// means they wall the destination off, and the caller should choose another.
    ///
    /// Pass `mustArrive` when the move has to actually finish on `dest`. Routing can
    /// legitimately return a partial move: if the cursor began inside an area and the
    /// way onward is walled off, getting out is still worth doing on its own. That is
    /// the right answer while wandering and the wrong one for a click approach.
    @discardableResult
    private func newPlayer(to dest: CGPoint, mustArrive: Bool = false) -> Bool {
        let waypoints: [CGPoint]
        if avoidBlockers.isEmpty {
            waypoints = [dest]
        } else {
            // Relax the one area whose comfort margin swallowed the destination, so a
            // click area placed right beside a no-go area is still reachable. The area
            // as drawn is still never entered.
            let blockers = AvoidZones.blockers(from: avoidRects, margin: avoidMargin, keepingReachable: dest)
            guard let detour = AvoidZones.route(from: currentPoint, to: dest,
                                                around: blockers,
                                                within: Geometry.visibleRegionsCG())
            else { return false }
            if mustArrive, let end = detour.last,
               hypot(end.x - dest.x, end.y - dest.y) > 0.5 { return false }
            waypoints = detour
        }

        var path = MovementEngine.randomizedWindMousePath(from: currentPoint, through: waypoints)
        if !avoidRects.isEmpty {
            path = AvoidZones.repair(path, keepingOutOf: avoidRects)
        }

        var speed = MovementEngine.randomSpeed(settings: settings)
        // Floor the speed so even a "very slow" pick can't make one move drag on
        // past maxMoveSeconds.
        let length = MovementEngine.pathLength(path)
        let minSpeed = length / maxMoveSeconds
        if speed < minSpeed { speed = minSpeed }
        player = PathPlayer(path: path, targetSpeed: speed, tremorAmplitude: settings.tremorAmplitude)
        return true
    }

    /// Advance the active move by `dt` and post the cursor. Clears `player` when done.
    private func advance(dt: TimeInterval) {
        guard let p = player else { return }
        if let pt = p.advance(by: dt) {
            // Last net before the event goes out: the planned path already clears the
            // no-go areas, so this only ever matters if the visible-region clamp or the
            // tremor nudged a point over the line. An area the cursor is already inside
            // is exempt, so a move on its way out is never snapped to the boundary.
            let posted = AvoidZones.contain(Geometry.clampToVisible(pt),
                                            enteringFrom: currentPoint,
                                            zones: avoidRects)
            currentPoint = posted
            input.move(to: posted)
        }
        if p.isFinished { player = nil }
    }
}
