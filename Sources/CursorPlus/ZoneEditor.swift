import AppKit
import CoreGraphics

/// Borderless full-screen overlay window that can become key (to receive Esc /
/// Delete / Return / Tab). Spans the union of all displays.
final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - Look of each zone kind

extension ZoneKind {
    var tint: NSColor { self == .click ? .systemBlue : .systemRed }

    var heading: String {
        self == .click ? "Click areas: the cursor may click inside these"
                       : "Avoid areas: the cursor never goes in these"
    }

    /// What the ⇥ hint offers to switch to.
    var switchLabel: String { self == .click ? "avoid areas" : "click areas" }
}

// MARK: - Editor view

/// Interactive rectangle editor. Holds zones as view-local rects (top-left origin,
/// `isFlipped = true`, so mouse math and drawing share one coordinate system).
/// Drag empty space = create; click = select (8 resize handles appear); drag a
/// handle = crop/resize; drag interior = move; Delete = remove; Tab = switch which
/// kind you are editing; Esc/Return = close.
///
/// The kind you are *not* editing is still drawn, dimmed and inert, because the two
/// interact: a click area buried inside an avoid area will never be clicked, and you
/// want to see that while you are drawing rather than wonder about it later.
final class ZoneEditorView: NSView {

    enum Handle: CaseIterable {
        case topLeft, top, topRight, left, right, bottomLeft, bottom, bottomRight
        func point(in r: CGRect) -> CGPoint {
            switch self {
            case .topLeft:     return CGPoint(x: r.minX, y: r.minY)
            case .top:         return CGPoint(x: r.midX, y: r.minY)
            case .topRight:    return CGPoint(x: r.maxX, y: r.minY)
            case .left:        return CGPoint(x: r.minX, y: r.midY)
            case .right:       return CGPoint(x: r.maxX, y: r.midY)
            case .bottomLeft:  return CGPoint(x: r.minX, y: r.maxY)
            case .bottom:      return CGPoint(x: r.midX, y: r.maxY)
            case .bottomRight: return CGPoint(x: r.maxX, y: r.maxY)
            }
        }
    }

    private enum HitTarget { case handle(Handle), interior(Int), empty }
    private enum DragMode { case none, creating, moving, resizing(Handle) }

    private(set) var rects: [CGRect] = []
    private(set) var kind: ZoneKind = .click
    private var backdrop: [CGRect] = []
    private var selected: Int?

    var onChange: (([CGRect]) -> Void)?
    var onSwitchKind: (() -> Void)?
    var onClose: (() -> Void)?

    private let minSize: CGFloat = 10
    private let handleSize: CGFloat = 9
    private let handleTolerance: CGFloat = 9

    private var mode: DragMode = .none
    private var dragStart: CGPoint = .zero
    private var originalRect: CGRect = .zero
    private var creating: CGRect = .zero

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Load one kind for editing, with the other kind shown behind it for reference.
    func load(kind: ZoneKind, rects: [CGRect], backdrop: [CGRect]) {
        self.kind = kind
        self.rects = rects
        self.backdrop = backdrop
        selected = nil
        mode = .none
        creating = .zero
        needsDisplay = true
    }

    // MARK: Hit testing (handles of selected first, then interiors top-most, then empty)

    private func hitTarget(at p: CGPoint) -> HitTarget {
        if let i = selected, rects.indices.contains(i) {
            for h in Handle.allCases {
                let c = h.point(in: rects[i])
                let grab = CGRect(x: c.x - handleTolerance, y: c.y - handleTolerance,
                                  width: handleTolerance * 2, height: handleTolerance * 2)
                if grab.contains(p) { return .handle(h) }
            }
        }
        for i in stride(from: rects.count - 1, through: 0, by: -1) {
            if rects[i].contains(p) { return .interior(i) }
        }
        return .empty
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        dragStart = p
        switch hitTarget(at: p) {
        case .handle(let h):
            guard let i = selected, rects.indices.contains(i) else { return }
            originalRect = rects[i]
            mode = .resizing(h)
        case .interior(let i):
            selected = i
            originalRect = rects[i]
            mode = .moving
        case .empty:
            selected = nil
            creating = CGRect(origin: p, size: .zero)
            mode = .creating
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        switch mode {
        case .creating:
            creating = normalized(from: dragStart, to: p)
        case .moving:
            guard let i = selected else { return }
            rects[i] = clampToBounds(originalRect.offsetBy(dx: p.x - dragStart.x, dy: p.y - dragStart.y))
        case .resizing(let h):
            guard let i = selected else { return }
            rects[i] = resize(originalRect, handle: h, to: p)
        case .none:
            break
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        switch mode {
        case .creating:
            if creating.width >= minSize && creating.height >= minSize {
                rects.append(clampToBounds(creating))
                selected = rects.count - 1
                onChange?(rects)
            }
            creating = .zero
        case .moving, .resizing:
            onChange?(rects)
        case .none:
            break
        }
        mode = .none
        needsDisplay = true
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 51, 117:                       // Delete / Forward-Delete
            if let i = selected, rects.indices.contains(i) {
                rects.remove(at: i)
                selected = nil
                onChange?(rects)
                needsDisplay = true
            }
        case 48:                            // Tab -> edit the other kind
            onSwitchKind?()
        case 53, 36, 76:                    // Esc / Return / Enter -> done
            onClose?()
        default:
            super.keyDown(with: event)
        }
    }

    // MARK: Geometry helpers

    private func normalized(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    private func resize(_ orig: CGRect, handle h: Handle, to p: CGPoint) -> CGRect {
        var left = orig.minX, right = orig.maxX, top = orig.minY, bottom = orig.maxY
        switch h {
        case .topLeft:     left = p.x; top = p.y
        case .top:         top = p.y
        case .topRight:    right = p.x; top = p.y
        case .left:        left = p.x
        case .right:       right = p.x
        case .bottomLeft:  left = p.x; bottom = p.y
        case .bottom:      bottom = p.y
        case .bottomRight: right = p.x; bottom = p.y
        }
        var r = CGRect(x: min(left, right), y: min(top, bottom),
                       width: abs(right - left), height: abs(bottom - top))
        if r.width < minSize { r.size.width = minSize }
        if r.height < minSize { r.size.height = minSize }
        return clampToBounds(r)
    }

    private func clampToBounds(_ r: CGRect) -> CGRect {
        var r = r
        r.size.width = min(r.width, bounds.width)
        r.size.height = min(r.height, bounds.height)
        r.origin.x = min(max(r.minX, bounds.minX), bounds.maxX - r.width)
        r.origin.y = min(max(r.minY, bounds.minY), bounds.maxY - r.height)
        return r
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        // Dim scrim so the user clearly sees they're in edit mode.
        NSColor.black.withAlphaComponent(0.32).setFill()
        bounds.fill()

        // The kind you are not editing, dimmed and inert, for context only.
        let otherTint = kind.other.tint
        for r in backdrop {
            otherTint.withAlphaComponent(0.10).setFill()
            r.fill()
            let p = NSBezierPath(rect: r)
            p.lineWidth = 1
            p.setLineDash([5, 4], count: 2, phase: 0)
            otherTint.withAlphaComponent(0.40).setStroke()
            p.stroke()
        }

        var live: [(CGRect, Bool)] = rects.enumerated().map { ($0.element, $0.offset == selected) }
        if case .creating = mode { live.append((creating, true)) }

        let tint = kind.tint
        for (r, sel) in live {
            tint.withAlphaComponent(sel ? 0.28 : 0.15).setFill()
            r.fill()
            // Hatching reads as "keep out" at a glance, so an avoid area can never be
            // mistaken for a click area even on a busy screen.
            if kind == .avoid { hatch(r, color: tint.withAlphaComponent(sel ? 0.55 : 0.35)) }
            let path = NSBezierPath(rect: r)
            path.lineWidth = sel ? 2 : 1
            tint.setStroke()
            path.stroke()
        }

        if let i = selected, rects.indices.contains(i) {
            NSColor.white.setFill()
            tint.setStroke()
            for h in Handle.allCases {
                let c = h.point(in: rects[i])
                let sq = CGRect(x: c.x - handleSize / 2, y: c.y - handleSize / 2,
                                width: handleSize, height: handleSize)
                let hp = NSBezierPath(rect: sq)
                hp.fill(); hp.lineWidth = 1; hp.stroke()
            }
        }

        drawHint()
    }

    /// 45° stripes clipped to `r`.
    private func hatch(_ r: CGRect, color: NSColor) {
        guard r.width > 1, r.height > 1 else { return }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: r).setClip()
        color.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1
        var x = r.minX - r.height
        while x < r.maxX {
            path.move(to: CGPoint(x: x, y: r.maxY))
            path.line(to: CGPoint(x: x + r.height, y: r.minY))
            x += 10
        }
        path.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawHint() {
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineSpacing = 2

        let text = NSMutableAttributedString(
            string: kind.heading + "\n",
            attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                         .foregroundColor: kind.tint.blended(withFraction: 0.45, of: .white) ?? .white,
                         .paragraphStyle: para])
        text.append(NSAttributedString(
            string: "drag to add  ·  click to select  ·  drag handles to crop  ·  ⌫ delete"
                  + "  ·  ⇥ switch to \(kind.switchLabel)  ·  esc/return done",
            attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium),
                         .foregroundColor: NSColor.white.withAlphaComponent(0.92),
                         .paragraphStyle: para]))

        let size = text.boundingRect(with: NSSize(width: bounds.width, height: .greatestFiniteMagnitude),
                                     options: [.usesLineFragmentOrigin]).size
        let pad: CGFloat = 10
        // Top of a flipped view is y = 0.
        let box = CGRect(x: bounds.midX - (size.width + pad * 2) / 2, y: 18,
                         width: size.width + pad * 2, height: size.height + pad * 2)
        NSColor.black.withAlphaComponent(0.62).setFill()
        NSBezierPath(roundedRect: box, xRadius: 7, yRadius: 7).fill()
        text.draw(with: box.insetBy(dx: pad, dy: pad), options: [.usesLineFragmentOrigin])
    }
}

// MARK: - Controller

/// Opens/closes the overlay editor and bridges its view-local rects to the CG
/// global top-left zones persisted in Settings.
final class ZoneEditorController {

    private let settings: Settings
    private var window: OverlayWindow?
    private var view: ZoneEditorView?

    /// Which kind is currently being edited.
    private(set) var kind: ZoneKind = .click

    /// Called after the editor closes (so the owner can clear its UI hold).
    var onClose: (() -> Void)?

    init(settings: Settings) {
        self.settings = settings
    }

    var isOpen: Bool { window != nil }

    func open(_ kind: ZoneKind) {
        if isOpen {
            if kind != self.kind { persist(); self.kind = kind; loadIntoView() }
            window?.makeKeyAndOrderFront(nil)
            return
        }
        self.kind = kind

        let frame = Self.unionScreenFrame()
        let win = OverlayWindow(contentRect: frame, styleMask: .borderless,
                                backing: .buffered, defer: false)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false
        win.level = .screenSaver
        win.ignoresMouseEvents = false
        win.isReleasedWhenClosed = false
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        win.setFrame(frame, display: true)

        let v = ZoneEditorView(frame: NSRect(origin: .zero, size: frame.size))
        v.autoresizingMask = [.width, .height]
        win.contentView = v
        self.window = win
        self.view = v

        // Convert persisted CG zones -> view-local for display (window is positioned now).
        loadIntoView()
        v.onChange = { [weak self] _ in self?.persist() }
        v.onSwitchKind = { [weak self] in self?.switchKind() }
        v.onClose = { [weak self] in self?.close() }

        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        win.makeFirstResponder(v)
    }

    func close() {
        persist()
        window?.orderOut(nil)
        window = nil
        view = nil
        onClose?()
    }

    /// Save what is on screen, then flip to editing the other kind in place.
    private func switchKind() {
        persist()
        kind = kind.other
        loadIntoView()
    }

    private func loadIntoView() {
        guard let v = view else { return }
        v.load(kind: kind,
               rects: settings.loadZones(kind).map { cgToLocal($0) },
               backdrop: settings.loadZones(kind.other).map { cgToLocal($0) })
    }

    private func persist() {
        guard let v = view else { return }
        settings.saveZones(v.rects.map { localToCG($0) }, v.kind)
    }

    // MARK: Coordinate conversion (view-local <-> CG global top-left)

    private func localToCG(_ local: CGRect) -> CGRect {
        guard let v = view, let w = window else { return local }
        let inWindow = v.convert(local, to: nil)
        let screen = w.convertToScreen(inWindow)
        return Geometry.cgRect(fromAppKit: screen)
    }

    private func cgToLocal(_ cg: CGRect) -> CGRect {
        guard let v = view, let w = window else { return cg }
        let screen = Geometry.cgRect(fromAppKit: cg)   // flip is its own inverse -> AppKit global
        let inWindow = w.convertFromScreen(screen)
        return v.convert(inWindow, from: nil)
    }

    /// Union of every screen's frame in AppKit (bottom-left) global coordinates.
    private static func unionScreenFrame() -> CGRect {
        let screens = NSScreen.screens
        guard let first = screens.first else { return .zero }
        return screens.dropFirst().reduce(first.frame) { $0.union($1.frame) }
    }
}
