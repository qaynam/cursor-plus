import AppKit
import CoreGraphics

/// Coordinate-space helpers. The whole tool works in **CG global coordinates**
/// (top-left origin, spanning all displays) because that is what `CGEvent` and
/// `CGEvent.location` use.
///
/// AppKit's `NSScreen` works in **bottom-left** global coordinates, so we flip
/// around the primary display's height whenever we borrow `visibleFrame`
/// (which conveniently excludes the menu bar and the Dock).
enum Geometry {

    /// Height of the primary display — the screen whose AppKit origin is (0,0).
    /// This is the pivot for the bottom-left <-> top-left flip.
    static var primaryHeight: CGFloat {
        NSScreen.screens.first { $0.frame.origin == .zero }?.frame.height
            ?? NSScreen.main?.frame.height
            ?? 0
    }

    /// AppKit global rect (bottom-left) -> CG global rect (top-left).
    static func cgRect(fromAppKit r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    /// Each screen's usable region (menu bar + Dock excluded) in CG coordinates.
    static func visibleRegionsCG() -> [CGRect] {
        NSScreen.screens.map { cgRect(fromAppKit: $0.visibleFrame) }
    }

    /// A random point inside some screen's visibleFrame, returned in CG (top-left)
    /// coordinates. Screens are weighted by visible area so multi-monitor setups
    /// roam proportionally. A small inset keeps motion off the very edge.
    static func randomVisiblePointCG(inset: CGFloat = 6) -> CGPoint {
        let regions = visibleRegionsCG()
        guard !regions.isEmpty else { return .zero }
        let areas = regions.map { Double(max($0.width, 0) * max($0.height, 0)) }
        let total = areas.reduce(0, +)
        var chosen = regions[0]
        if total > 0 {
            var roll = Double.random(in: 0..<total)
            for (i, r) in regions.enumerated() {
                if roll < areas[i] { chosen = r; break }
                roll -= areas[i]
            }
        }
        let r = chosen.insetBy(dx: min(inset, chosen.width / 2),
                               dy: min(inset, chosen.height / 2))
        let x = CGFloat.random(in: r.minX...max(r.minX, r.maxX))
        let y = CGFloat.random(in: r.minY...max(r.minY, r.maxY))
        return CGPoint(x: x, y: y)
    }

    /// A random point inside some screen's visibleFrame that is not inside any of
    /// `blockers`. Returns nil when the blockers leave nowhere to go, so the caller
    /// can take a breather instead of forcing a move it would have to correct.
    static func randomVisiblePointCG(avoiding blockers: [CGRect], inset: CGFloat = 6) -> CGPoint? {
        guard !blockers.isEmpty else { return randomVisiblePointCG(inset: inset) }

        // Rejection sampling: for any sane layout this keeps exactly the same
        // area-weighted, screen-weighted distribution as the unobstructed case.
        for _ in 0..<48 {
            let p = randomVisiblePointCG(inset: inset)
            if !blockers.contains(where: { $0.contains(p) }) { return p }
        }

        // Blocked areas cover most of the screen. Fall back to a coarse cell scan so a
        // small free pocket is still found, picking among free CELLS so the result
        // stays roughly area-uniform rather than clustering on one lucky sample.
        let cols = 24, rows = 16
        var free: [CGRect] = []
        for region in visibleRegionsCG() {
            let r = region.insetBy(dx: min(inset, region.width / 2),
                                   dy: min(inset, region.height / 2))
            guard r.width > 0, r.height > 0 else { continue }
            let cw = r.width / CGFloat(cols), ch = r.height / CGFloat(rows)
            for i in 0..<cols {
                for j in 0..<rows {
                    let cell = CGRect(x: r.minX + CGFloat(i) * cw, y: r.minY + CGFloat(j) * ch,
                                      width: cw, height: ch)
                    let c = CGPoint(x: cell.midX, y: cell.midY)
                    if !blockers.contains(where: { $0.contains(c) }) { free.append(cell) }
                }
            }
        }
        guard let cell = free.randomElement() else { return nil }
        for _ in 0..<12 {
            let p = CGPoint(x: CGFloat.random(in: cell.minX...cell.maxX),
                            y: CGFloat.random(in: cell.minY...cell.maxY))
            if !blockers.contains(where: { $0.contains(p) }) { return p }
        }
        return CGPoint(x: cell.midX, y: cell.midY)
    }

    /// Clamp a CG point into the nearest visible region so motion never wanders
    /// onto the menu bar / off-screen.
    static func clampToVisible(_ p: CGPoint) -> CGPoint {
        let regions = visibleRegionsCG()
        guard !regions.isEmpty else { return p }
        if regions.contains(where: { $0.contains(p) }) { return p }
        // Snap to the region whose center is nearest.
        var best = regions[0]
        var bestDist = Double.greatestFiniteMagnitude
        for r in regions {
            let c = CGPoint(x: r.midX, y: r.midY)
            let d = Double(hypot(c.x - p.x, c.y - p.y))
            if d < bestDist { bestDist = d; best = r }
        }
        return CGPoint(x: min(max(p.x, best.minX), best.maxX),
                       y: min(max(p.y, best.minY), best.maxY))
    }
}
