import Foundation
import CoreGraphics

/// The two kinds of user-drawn rectangle Cursor+ understands. Both are stored in
/// CG global TOP-LEFT coordinates and edited with the same overlay editor.
enum ZoneKind: CaseIterable {
    /// Somewhere the cursor may occasionally curve to and click.
    case click
    /// Somewhere the cursor must never enter: it is never chosen as a target and
    /// every path is routed around it.
    case avoid

    var other: ZoneKind { self == .click ? .avoid : .click }
}

/// A user-defined rectangular region, stored in CG global TOP-LEFT coordinates
/// (the same plane CGEvent / the cursor use). Persisted as JSON in UserDefaults.
/// Codable via plain Doubles because CGRect is not Codable out of the box.
///
/// The same shape backs both click areas and avoid areas, so the on-disk format
/// for the two lists is identical.
struct ZoneRect: Codable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    init(rect: CGRect) {
        x = Double(rect.minX)
        y = Double(rect.minY)
        width = Double(rect.width)
        height = Double(rect.height)
    }

    var rect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }

    /// A random point inside the zone, biased toward the center (CG global top-left).
    /// Real clicks cluster toward a target's middle with a roughly bell-shaped scatter
    /// and rarely hit the exact edge — a flat uniform draw is the bot tell. The mean
    /// of three uniforms approximates that bell, centered on the zone center.
    func randomPoint() -> CGPoint {
        let r = rect
        func biased(_ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
            guard hi > lo else { return lo }
            return (CGFloat.random(in: lo...hi)
                  + CGFloat.random(in: lo...hi)
                  + CGFloat.random(in: lo...hi)) / 3
        }
        return CGPoint(x: biased(r.minX, r.maxX), y: biased(r.minY, r.maxY))
    }
}
