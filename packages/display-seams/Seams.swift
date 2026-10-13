// Display layout and pointer mapping for display-seams, free of AppKit and
// CoreGraphics so the tests can run anywhere Swift does.
//
// Coordinates are macOS's global display space in points: origin at the top
// left of the main display, y growing downward (CGDisplayBounds, CGEvent).
//
// macOS lets the pointer cross only where two displays' edges overlap in the
// arrangement. Here every edge with at least one neighbor is spread over all
// of its neighbors instead: the edge is cut into one segment per neighbor,
// sized in proportion to the overlap with that neighbor, and each segment maps
// linearly onto the segment of the neighbor's facing edge that belongs back to
// this display. Two displays side by side therefore join along their full
// heights; a display beside two others splits its edge between them by how
// much each overlaps it. Mapping back across the same seam is the inverse, so
// a round trip lands where it started.

struct Point: Equatable {
  var x: Double
  var y: Double
}

struct Rect: Equatable {
  var minX: Double
  var minY: Double
  var maxX: Double
  var maxY: Double

  init(x: Double, y: Double, width: Double, height: Double) {
    minX = x
    minY = y
    maxX = x + width
    maxY = y + height
  }

  func contains(_ p: Point) -> Bool {
    p.x >= minX && p.x < maxX && p.y >= minY && p.y < maxY
  }

  // The coordinate of the line this edge lies on.
  func edge(_ side: Side) -> Double {
    switch side {
    case .left: return minX
    case .right: return maxX
    case .top: return minY
    case .bottom: return maxY
    }
  }

  // The extent of this edge along the seam.
  func span(_ side: Side) -> (lo: Double, hi: Double) {
    side.isVertical ? (minY, maxY) : (minX, maxX)
  }
}

struct Display: Equatable {
  var id: UInt32
  var frame: Rect
}

enum Side: CaseIterable, CustomStringConvertible {
  case left, right, top, bottom

  var opposite: Side {
    switch self {
    case .left: return .right
    case .right: return .left
    case .top: return .bottom
    case .bottom: return .top
    }
  }

  // Left and right edges are vertical lines: crossing them moves along x.
  var isVertical: Bool { self == .left || self == .right }

  // Whether leaving through this edge increases the crossing coordinate.
  var isIncreasing: Bool { self == .right || self == .bottom }

  var description: String {
    switch self {
    case .left: return "left"
    case .right: return "right"
    case .top: return "top"
    case .bottom: return "bottom"
    }
  }

  // The coordinate that crosses this edge, and the one that runs along it.
  func normal(_ p: Point) -> Double { isVertical ? p.x : p.y }
  func along(_ p: Point) -> Double { isVertical ? p.y : p.x }
  func point(normal n: Double, along a: Double) -> Point {
    isVertical ? Point(x: n, y: a) : Point(x: a, y: n)
  }
}

// The pointer can sit at most this close to an edge it is pressed against:
// macOS keeps it on the last point inside the display.
let edgeReach = 1.0

struct Segment: Equatable {
  // Index of the neighbor into Layout.displays.
  var neighbor: Int
  // The part of this display's edge that maps onto the neighbor.
  var lo: Double
  var hi: Double
  // Where the two edges really overlap; macOS crosses here on its own.
  var overlapLo: Double
  var overlapHi: Double
}

struct Layout {
  let displays: [Display]
  // segments[i][side]: display i's edge on that side, cut up by neighbor.
  private let segments: [[Side: [Segment]]]

  init(_ displays: [Display]) {
    self.displays = displays
    segments = displays.indices.map { i in
      Dictionary(uniqueKeysWithValues: Side.allCases.map { side in
        (side, Layout.cut(displays, i, side))
      })
    }
  }

  func index(containing p: Point) -> Int? {
    displays.firstIndex { $0.frame.contains(p) }
  }

  func segments(of i: Int, _ side: Side) -> [Segment] {
    segments[i][side] ?? []
  }

  // Whether the pointer pressed against this edge at `a` is stuck: the edge
  // has neighbors, but none that macOS would carry it over to from here.
  func isDead(_ i: Int, _ side: Side, along a: Double) -> Bool {
    let segs = segments(of: i, side)
    return !segs.isEmpty && !segs.contains { a >= $0.overlapLo && a <= $0.overlapHi - edgeReach }
  }

  // Where leaving display i through `side` at `a` should come out: the
  // neighbor and the point just inside its facing edge.
  func map(from i: Int, _ side: Side, along a: Double) -> (display: Int, point: Point)? {
    let segs = segments(of: i, side)
    guard let last = segs.last else { return nil }
    let span = displays[i].frame.span(side)
    let a = min(max(a, span.lo), span.hi)
    let seg = segs.first { a < $0.hi } ?? last
    let j = seg.neighbor
    guard let back = segments(of: j, side.opposite).first(where: { $0.neighbor == i }) else { return nil }
    let t = seg.hi > seg.lo ? (a - seg.lo) / (seg.hi - seg.lo) : 0
    let target = displays[j].frame
    let targetSpan = target.span(side)
    let along = min(max(back.lo + t * (back.hi - back.lo), targetSpan.lo), targetSpan.hi - edgeReach)
    let edge = target.edge(side.opposite)
    let normal = side.isIncreasing ? edge + edgeReach : edge - 2 * edgeReach
    return (j, side.point(normal: normal, along: along))
  }

  private static func cut(_ displays: [Display], _ i: Int, _ side: Side) -> [Segment] {
    let frame = displays[i].frame
    let span = frame.span(side)
    let neighbors = displays.indices.compactMap { j -> (Int, Double, Double)? in
      guard j != i else { return nil }
      let other = displays[j].frame
      guard abs(other.edge(side.opposite) - frame.edge(side)) < 0.5 else { return nil }
      let otherSpan = other.span(side)
      let lo = max(span.lo, otherSpan.lo)
      let hi = min(span.hi, otherSpan.hi)
      return hi - lo > 0.5 ? (j, lo, hi) : nil
    }.sorted { $0.1 < $1.1 }
    let total = neighbors.reduce(0) { $0 + ($1.2 - $1.1) }
    guard total > 0 else { return [] }
    var cursor = span.lo
    var covered = 0.0
    return neighbors.map { j, lo, hi in
      covered += hi - lo
      let end = span.lo + (span.hi - span.lo) * covered / total
      defer { cursor = end }
      return Segment(neighbor: j, lo: cursor, hi: end, overlapLo: lo, overlapHi: hi)
    }
  }
}

// Turns a stream of pointer motion into warps: across the dead part of an
// edge after the pointer has been pushed into it for `dwell` seconds, and
// onto the proportional position whenever macOS carries it across a real
// overlap by itself.
final class Bridge {
  private(set) var layout: Layout
  let dwell: Double
  // A push only counts as continuing while events keep arriving this often.
  let idleReset: Double
  // How long after a warp events may still report where the pointer was
  // before it: macOS delivers ones already queued, and those must not read
  // as a step back across the seam.
  let settle: Double

  // Whether the last event fed in was one of those and was ignored.
  private(set) var ignoredStale = false

  private var push: (display: Int, side: Side, since: Double)?
  private var last: (point: Point, time: Double)?
  private var warp: (target: Point, until: Double)?

  init(_ displays: [Display], dwell: Double = 0.04, idleReset: Double = 0.1, settle: Double = 0.25) {
    layout = Layout(displays)
    self.dwell = dwell
    self.idleReset = idleReset
    self.settle = settle
  }

  func setDisplays(_ displays: [Display]) {
    layout = Layout(displays)
    push = nil
    last = nil
    warp = nil
  }

  // Feed one motion event: where the pointer is now and how far the device
  // moved (unclamped, so it still reports a push against an edge). Returns
  // the point to warp to, if any.
  func handle(location: Point, delta: Point, time: Double) -> Point? {
    ignoredStale = false
    if let warp {
      // After the warp shows up, the pointer is at most one step from it.
      let slack = abs(delta.x) + abs(delta.y) + 8
      let distance = abs(location.x - warp.target.x) + abs(location.y - warp.target.y)
      if distance > slack && time < warp.until {
        ignoredStale = true
        return nil
      }
      self.warp = nil
    }

    let previous = last
    last = (location, time)
    guard let i = layout.index(containing: location) else {
      push = nil
      return nil
    }

    if let previous, let p = layout.index(containing: previous.point), p != i {
      push = nil
      return crossing(from: p, at: previous.point, into: i, at: location, delta: delta).map { warped($0, time) }
    }

    guard let (side, a) = pinned(i, location, delta) else {
      push = nil
      return nil
    }
    if let push, push.display == i, push.side == side, let previous, time - previous.time <= idleReset {
      guard time - push.since >= dwell, let (_, target) = layout.map(from: i, side, along: a) else {
        return nil
      }
      self.push = nil
      return warped(target, time)
    }
    push = (i, side, time)
    return nil
  }

  private func warped(_ target: Point, _ time: Double) -> Point {
    last = (target, time)
    warp = (target, time + settle)
    return target
  }

  // The dead edge the pointer is pressed against, if any; at a corner, the
  // one it pushes into harder.
  private func pinned(_ i: Int, _ p: Point, _ delta: Point) -> (Side, Double)? {
    let frame = layout.displays[i].frame
    var best: (side: Side, along: Double, force: Double)?
    for side in Side.allCases {
      let n = side.normal(p)
      let d = side.normal(delta)
      let atEdge = side.isIncreasing ? n >= frame.edge(side) - edgeReach : n < frame.edge(side) + edgeReach
      let force = side.isIncreasing ? d : -d
      let a = side.along(p)
      guard atEdge, force > 0, layout.isDead(i, side, along: a) else { continue }
      if best == nil || force > best!.force { best = (side, a, force) }
    }
    return best.map { ($0.side, $0.along) }
  }

  // macOS moved the pointer from display p to display i across a real
  // overlap. Put it where the proportional mapping says instead, keeping the
  // part of the step that ran along the seam.
  private func crossing(from p: Int, at prev: Point, into i: Int, at cur: Point, delta: Point) -> Point? {
    let frame = layout.displays[p].frame
    for side in Side.allCases where layout.segments(of: p, side).contains(where: { $0.neighbor == i }) {
      let seam = frame.edge(side)
      let reach = abs(side.normal(delta)) + 2 * edgeReach
      let (pn, cn) = (side.normal(prev), side.normal(cur))
      // Both ends of the step sit at this seam: a step across it, not a jump
      // made by someone else's warp (spicy recentring a captured pointer).
      guard abs(pn - seam) <= reach, abs(cn - seam) <= reach else { continue }
      // Where along the seam the step crossed it.
      let (pa, ca) = (side.along(prev), side.along(cur))
      let f = cn != pn ? min(max((seam - pn) / (cn - pn), 0), 1) : 0
      let crossed = pa + (ca - pa) * f
      guard let (j, entry) = layout.map(from: p, side, along: crossed) else { return nil }
      let span = layout.displays[j].frame.span(side)
      let along = min(max(side.along(entry) + (ca - crossed), span.lo), span.hi - edgeReach)
      if j != i { return side.point(normal: side.normal(entry), along: along) }
      return abs(along - ca) > edgeReach ? side.point(normal: cn, along: along) : nil
    }
    return nil
  }
}
