import Foundation
import CoreGraphics

/// Keeps the wandering cursor out of the rectangles the user marked as off limits.
///
/// The hard part is not staying out, it is staying out while still looking like a
/// hand. Clamping a point at the edge of a forbidden box would make the cursor slide
/// along an invisible wall, which is both ugly and a far louder tell than the motion
/// it is protecting. So the work happens in three layers, front loaded so the last
/// one almost never has anything to do:
///
///  1. **Targets.** A destination, whether a wander point or a click, is never chosen
///     inside a no-go area, so the cursor never even aims at one.
///  2. **Routing.** Before a path exists, the straight line to the target is tested
///     against the areas inflated by a randomized comfort margin. If it would cut
///     through, a shortest detour is found through the corners of those inflated
///     rectangles, and WindMouse swings through the corners as via-points. What comes
///     out is one continuous curve around the obstacle, not a straight line with a
///     corner bolted onto it.
///  3. **Nets.** The generated polyline is checked against the rectangles as drawn,
///     and one last test before each posted point makes crossing in impossible.
///
/// The margin in step 2 is what buys the realism: it absorbs WindMouse's natural
/// wander, so step 3 has nothing to correct and no wall-hugging ever appears. The
/// margin is re-rolled every move, so the clearance is not a constant signature
/// either.
///
/// Pure geometry, no AppKit and no OS calls, so it is trivially testable on its own.
enum AvoidZones {

    /// How far outside a rectangle as drawn a path point must stay. The routing
    /// margin normally keeps motion far wider than this; it is the hard floor.
    static let hardClearance: CGFloat = 2

    /// How far outside a rectangle a *target* may be placed. Small on purpose: the
    /// user is allowed to put a click area right up against a no-go area.
    static let targetClearance: CGFloat = 6

    /// Rectangles closer to a segment than this are treated as touching it, so a
    /// path that grazes an edge or a corner is not counted as passing through.
    private static let interiorEpsilon: CGFloat = 0.5

    /// Corner nodes are pushed off their rectangle by at least this much, so a routing
    /// node is never exactly on a boundary.
    private static let cornerNudge: CGFloat = 1.0

    /// Extra random push on each corner node. Without it every detour would hug the
    /// same geometrically perfect tangent, which is its own repeating signature.
    private static let cornerJitter: ClosedRange<CGFloat> = 0...14

    /// Upper bound on how many areas contribute corner nodes to one route, so a user
    /// with an absurd number of areas cannot make path planning expensive. Every area
    /// still blocks every edge, and all of them are still enforced by the nets, so
    /// this only ever costs a longer detour, never a crossing.
    private static let routingCornerCap = 24

    // MARK: - Blockers

    /// A fresh comfort margin for one move. Wide enough to swallow WindMouse's wander
    /// (a handful of pixels either side of the planned line) without being so wide it
    /// walls off a normal screen.
    static func randomMargin() -> CGFloat { CGFloat.random(in: 20...36) }

    /// The user's rectangles inflated into routing obstacles.
    ///
    /// `keepingReachable` handles the one case where a full margin would be wrong: a
    /// target the user deliberately placed just outside a no-go area. Inflating would
    /// swallow it and make it unreachable, so the area that swallowed it falls back to
    /// its hard boundary for this move. The area itself is still never entered.
    static func blockers(from rects: [CGRect],
                         margin: CGFloat,
                         keepingReachable target: CGPoint? = nil) -> [CGRect] {
        rects.compactMap { r -> CGRect? in
            guard r.width > 0, r.height > 0,
                  r.origin.x.isFinite, r.origin.y.isFinite,
                  r.width.isFinite, r.height.isFinite else { return nil }
            let inflated = r.insetBy(dx: -margin, dy: -margin)
            guard let t = target, inflated.contains(t) else { return inflated }
            // The target sits in this area's comfort margin. Give up only as much
            // berth as it takes to leave the target outside, rather than dropping
            // straight to the hard floor: a click area 30px from a no-go area still
            // gets a 30px approach corridor, not a 2px one.
            let gap = max(max(r.minX - t.x, t.x - r.maxX),
                          max(r.minY - t.y, t.y - r.maxY))
            let relaxed = min(margin, max(hardClearance, gap - 0.5))
            let out = r.insetBy(dx: -relaxed, dy: -relaxed)
            // A target inside even the hard boundary should have been filtered out
            // upstream; dropping the blocker is the safe degenerate answer.
            return out.contains(t) ? nil : out
        }
    }

    /// The rectangles as drawn, grown by the clearance a target has to respect.
    static func targetBlockers(from rects: [CGRect]) -> [CGRect] {
        blockers(from: rects, margin: targetClearance)
    }

    static func contains(_ p: CGPoint, in rects: [CGRect]) -> Bool {
        rects.contains { $0.contains(p) }
    }

    // MARK: - Segment tests

    /// True if the segment `a`->`b` passes through the interior of `rect`. Grazing an
    /// edge or a corner does not count, which is exactly what corner routing needs.
    /// Liang-Barsky: clip the segment to the rectangle and see if anything survives.
    static func segmentCrosses(_ a: CGPoint, _ b: CGPoint, _ rect: CGRect) -> Bool {
        let r = rect.insetBy(dx: interiorEpsilon, dy: interiorEpsilon)
        guard r.width > 0, r.height > 0 else { return false }

        var t0 = 0.0, t1 = 1.0
        let dx = Double(b.x - a.x), dy = Double(b.y - a.y)
        let p = [-dx, dx, -dy, dy]
        let q = [Double(a.x - r.minX), Double(r.maxX - a.x),
                 Double(a.y - r.minY), Double(r.maxY - a.y)]

        for i in 0..<4 {
            if abs(p[i]) < 1e-12 {
                if q[i] < 0 { return false }     // parallel to this edge and outside it
            } else {
                let t = q[i] / p[i]
                if p[i] < 0 {
                    if t > t1 { return false }
                    if t > t0 { t0 = t }
                } else {
                    if t < t0 { return false }
                    if t < t1 { t1 = t }
                }
            }
        }
        return t1 - t0 > 1e-9                    // a positive-length piece is inside
    }

    static func segmentBlocked(_ a: CGPoint, _ b: CGPoint, by rects: [CGRect]) -> Bool {
        rects.contains { segmentCrosses(a, b, $0) }
    }

    // MARK: - Getting out

    /// The four ways out of `r` from `p`, nearest first.
    private static func exits(_ p: CGPoint, of r: CGRect, extra: CGFloat) -> [CGPoint] {
        [(p.x - r.minX, CGPoint(x: r.minX - extra, y: p.y)),
         (r.maxX - p.x, CGPoint(x: r.maxX + extra, y: p.y)),
         (p.y - r.minY, CGPoint(x: p.x, y: r.minY - extra)),
         (r.maxY - p.y, CGPoint(x: p.x, y: r.maxY + extra))]
            .sorted { $0.0 < $1.0 }
            .map { $0.1 }
    }

    /// Shortest push that puts `p` outside `r`.
    static func push(_ p: CGPoint, outOf r: CGRect, extra: CGFloat) -> CGPoint {
        exits(p, of: r, extra: extra)[0]
    }

    /// Push `p` out of every rectangle it is inside, shortest way each time.
    static func push(_ p: CGPoint, outOf rects: [CGRect], extra: CGFloat) -> CGPoint {
        var q = p
        for _ in 0..<4 {
            guard let r = rects.first(where: { $0.contains(q) }) else { break }
            q = push(q, outOf: r, extra: extra)
        }
        return q
    }

    /// A way out of the areas `p` sits inside, preferring an exit that lands on a
    /// screen and does not walk straight into another area. Used when the user parked
    /// the cursor inside a no-go area before walking away: leaving is legitimate, and
    /// leaving toward the nearest edge of the screen is not.
    static func escape(_ p: CGPoint, from rects: [CGRect], within bounds: [CGRect], extra: CGFloat) -> CGPoint {
        func onScreen(_ c: CGPoint) -> Bool { bounds.isEmpty || bounds.contains { $0.contains(c) } }
        var q = p
        for _ in 0..<4 {
            guard let r = rects.first(where: { $0.contains(q) }) else { break }
            let candidates = exits(q, of: r, extra: extra)
            q = candidates.first { onScreen($0) && !contains($0, in: rects) }
                ?? candidates.first { onScreen($0) }
                ?? candidates[0]
        }
        return q
    }

    // MARK: - Routing

    /// Waypoints from `start` to `to` that never cross a blocker, the destination
    /// included and the start excluded. `nil` means the blockers wall the destination
    /// off entirely, which the caller should answer by picking a different target.
    ///
    /// The one exception: if the cursor began inside an area, the way out is returned
    /// even when the rest of the route fails, because getting out always beats staying.
    static func route(from start: CGPoint,
                      to dest: CGPoint,
                      around blockers: [CGRect],
                      within bounds: [CGRect] = []) -> [CGPoint]? {
        guard !blockers.isEmpty else { return [dest] }

        var prefix: [CGPoint] = []
        var origin = start
        if contains(start, in: blockers) {
            origin = escape(start, from: blockers, within: bounds, extra: cornerNudge)
            prefix = [origin]
        }

        // A destination inside a blocker should already have been filtered out; nudge
        // it clear rather than planning a route that ends somewhere forbidden.
        var target = dest
        if contains(target, in: blockers) {
            target = escape(target, from: blockers, within: bounds, extra: cornerNudge)
        }

        if !segmentBlocked(origin, target, by: blockers) { return prefix + [target] }

        var nodes: [CGPoint] = [origin, target]
        for r in cornerSources(blockers, between: origin, and: target) {
            for c in jitteredCorners(of: r) where !contains(c, in: blockers) {
                nodes.append(c)
            }
        }

        guard let order = shortestPath(nodes: nodes, from: 0, to: 1, blockers: blockers) else {
            return prefix.isEmpty ? nil : prefix
        }
        return prefix + order.dropFirst().map { nodes[$0] }
    }

    /// The areas whose corners are worth considering for this move. Everything blocks
    /// every edge; this only bounds how many nodes the graph carries.
    private static func cornerSources(_ rects: [CGRect], between a: CGPoint, and b: CGPoint) -> [CGRect] {
        guard rects.count > routingCornerCap else { return rects }
        let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        return rects
            .map { ($0, Double(hypot($0.midX - mid.x, $0.midY - mid.y))) }
            .sorted { $0.1 < $1.1 }
            .prefix(routingCornerCap)
            .map { $0.0 }
    }

    /// The four corners of `r`, each pushed out along its own diagonal by the nudge
    /// plus a random extra. Outward only, so a jittered corner is always further from
    /// its own rectangle, never closer.
    private static func jitteredCorners(of r: CGRect) -> [CGPoint] {
        [(false, false), (true, false), (false, true), (true, true)].map { (right, down) in
            let dx = cornerNudge + CGFloat.random(in: cornerJitter)
            let dy = cornerNudge + CGFloat.random(in: cornerJitter)
            return CGPoint(x: right ? r.maxX + dx : r.minX - dx,
                           y: down  ? r.maxY + dy : r.minY - dy)
        }
    }

    /// Dijkstra over the visibility graph of `nodes`. Dense and O(n^2) on purpose:
    /// a handful of areas means well under a hundred nodes, and the distance check
    /// runs before the segment test so most edges cost almost nothing.
    private static func shortestPath(nodes: [CGPoint], from s: Int, to t: Int, blockers: [CGRect]) -> [Int]? {
        let n = nodes.count
        guard n > 1, nodes.indices.contains(s), nodes.indices.contains(t), s != t else { return nil }

        var dist = [Double](repeating: .greatestFiniteMagnitude, count: n)
        var prev = [Int](repeating: -1, count: n)
        var done = [Bool](repeating: false, count: n)
        dist[s] = 0

        for _ in 0..<n {
            var u = -1
            var best = Double.greatestFiniteMagnitude
            for i in 0..<n where !done[i] && dist[i] < best { best = dist[i]; u = i }
            if u < 0 || u == t { break }
            done[u] = true

            for v in 0..<n where !done[v] && v != u {
                let w = Double(hypot(nodes[v].x - nodes[u].x, nodes[v].y - nodes[u].y))
                guard dist[u] + w < dist[v] else { continue }
                guard !segmentBlocked(nodes[u], nodes[v], by: blockers) else { continue }
                dist[v] = dist[u] + w
                prev[v] = u
            }
        }

        guard dist[t] < .greatestFiniteMagnitude else { return nil }

        var order = [t]
        var cur = t
        var hops = 0
        while cur != s && hops <= n {
            cur = prev[cur]
            guard cur >= 0 else { return nil }
            order.append(cur)
            hops += 1
        }
        guard cur == s else { return nil }
        return order.reversed()
    }

    // MARK: - Nets

    /// Push any generated point that landed inside a no-go area back out, keeping the
    /// hard clearance. The routing margin normally absorbs WindMouse's wander, so this
    /// rarely touches anything; the small random extra keeps a rare run of corrected
    /// points from reading as a flat line ruled against the edge.
    ///
    /// A path that *starts* inside an area is walking out of one, so its leading run
    /// is left alone. Correcting those points would snap the cursor to the boundary
    /// the moment the tool resumed.
    static func repair(_ path: [CGPoint], keepingOutOf rects: [CGRect]) -> [CGPoint] {
        guard !rects.isEmpty, !path.isEmpty else { return path }
        let hard = rects.map { $0.insetBy(dx: -hardClearance, dy: -hardClearance) }

        var out = path
        var leaving = contains(out[0], in: hard)
        for i in out.indices {
            let inside = contains(out[i], in: hard)
            if leaving {
                if inside { continue }
                leaving = false
            }
            if inside {
                out[i] = push(out[i], outOf: hard, extra: CGFloat.random(in: 0...3))
            }
        }
        return out
    }

    /// The last check before a point is posted: never cross *into* a no-go area. An
    /// area the cursor is already inside is exempt, so a move that is on its way out
    /// is allowed to finish. Per area, so being inside one is never a licence to
    /// enter another.
    static func contain(_ p: CGPoint, enteringFrom prev: CGPoint, zones: [CGRect]) -> CGPoint {
        guard !zones.isEmpty else { return p }
        var q = p
        for _ in 0..<3 {
            guard let r = zones.first(where: { $0.contains(q) && !$0.contains(prev) }) else { break }
            q = push(q, outOf: r, extra: 1)
        }
        return q
    }
}
