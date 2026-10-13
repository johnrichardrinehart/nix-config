// Tests for Seams.swift, built together with it: swiftc Seams.swift tests/main.swift
#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

var failures = 0

func check(_ ok: Bool, _ what: String, line: Int = #line) {
  if !ok {
    failures += 1
    print("FAIL line \(line): \(what)")
  }
}

func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-6 }

func expect(_ p: Point?, _ x: Double, _ y: Double, _ what: String, line: Int = #line) {
  guard let p else { return check(false, "\(what): no warp, wanted (\(x), \(y))", line: line) }
  check(near(p.x, x) && near(p.y, y), "\(what): got (\(p.x), \(p.y)), wanted (\(x), \(y))", line: line)
}

func expectNone(_ p: Point?, _ what: String, line: Int = #line) {
  check(p == nil, "\(what): unexpected warp to \(String(describing: p))", line: line)
}

func display(_ id: UInt32, _ x: Double, _ y: Double, _ w: Double, _ h: Double) -> Display {
  Display(id: id, frame: Rect(x: x, y: y, width: w, height: h))
}

let push = Point(x: 5, y: 0)

// A 1440-point-tall display with a 1080-point one to its right, whose top
// sits 600 points lower: only y 600..1440 of the edge meets.
let big = display(1, 0, 0, 2560, 1440)
let small = display(2, 2560, 600, 1920, 1080)

do {
  let layout = Layout([big, small])
  // The whole height of each maps onto the whole height of the other.
  check(layout.map(from: 0, .right, along: 0)! == (1, Point(x: 2561, y: 600)), "top of big -> top of small")
  check(near(layout.map(from: 0, .right, along: 720)!.point.y, 1140), "middle -> middle")
  check(near(layout.map(from: 0, .right, along: 1440)!.point.y, 1679), "bottom clamps inside small")
  check(layout.map(from: 1, .left, along: 600)! == (0, Point(x: 2558, y: 0)), "top of small -> top of big")
  check(near(layout.map(from: 1, .left, along: 1140)!.point.y, 720), "middle back")
  for y in stride(from: 0.0, to: 1439, by: 97) {
    let there = layout.map(from: 0, .right, along: y)!.point.y
    check(near(layout.map(from: 1, .left, along: there)!.point.y, y), "round trip from \(y)")
  }
  // Only the unmatched part of the edge is dead; the outer edges have no neighbor.
  check(layout.isDead(0, .right, along: 100), "y 100 is dead")
  check(!layout.isDead(0, .right, along: 1000), "y 1000 crosses natively")
  check(!layout.isDead(0, .left, along: 100), "no neighbor on the left")
  check(layout.map(from: 0, .left, along: 100) == nil, "nothing to map to on the left")
}

do {
  // Pushing into the dead part warps only after the dwell.
  let bridge = Bridge([big, small], dwell: 0.04)
  expectNone(bridge.handle(location: Point(x: 2559, y: 100), delta: push, time: 0), "first push")
  expectNone(bridge.handle(location: Point(x: 2559, y: 100), delta: push, time: 0.02), "inside the dwell")
  expect(bridge.handle(location: Point(x: 2559, y: 100), delta: push, time: 0.05), 2561, 675, "after the dwell")
  // The next step on the far side is not taken for a crossing and bounced.
  expectNone(bridge.handle(location: Point(x: 2565, y: 676), delta: Point(x: 4, y: 1), time: 0.06), "after warp")
}

do {
  // Resting against the edge or sliding along it does not warp.
  let bridge = Bridge([big, small], dwell: 0.04)
  expectNone(bridge.handle(location: Point(x: 2559, y: 100), delta: Point(x: 0, y: 3), time: 0), "slide")
  expectNone(bridge.handle(location: Point(x: 2559, y: 103), delta: Point(x: 0, y: 3), time: 0.05), "slide on")
  expectNone(bridge.handle(location: Point(x: 2559, y: 103), delta: Point(x: -3, y: 0), time: 0.1), "pull back")
}

do {
  // A pointer recentred after every move (spicy holding it in server mouse
  // mode) never stays at the edge for the whole dwell.
  let bridge = Bridge([big, small], dwell: 0.04)
  let centre = Point(x: 1280, y: 720)
  var t = 0.0
  for _ in 0..<10 {
    expectNone(bridge.handle(location: Point(x: 2559, y: 100), delta: push, time: t), "captured, at edge")
    expectNone(bridge.handle(location: centre, delta: push, time: t + 0.01), "captured, recentred")
    t += 0.02
  }
  // A recentring jump is not a crossing either.
  let bridge2 = Bridge([big, small], dwell: 0.04)
  expectNone(bridge2.handle(location: Point(x: 2559, y: 1000), delta: push, time: 0), "near seam")
  expectNone(bridge2.handle(location: Point(x: 3500, y: 1100), delta: push, time: 0.01), "jump into small")
}

do {
  // A pause restarts the dwell.
  let bridge = Bridge([big, small], dwell: 0.04, idleReset: 0.1)
  expectNone(bridge.handle(location: Point(x: 2559, y: 100), delta: push, time: 0), "push")
  expectNone(bridge.handle(location: Point(x: 2559, y: 100), delta: push, time: 0.5), "after a pause")
  expect(bridge.handle(location: Point(x: 2559, y: 100), delta: push, time: 0.55), 2561, 675, "dwell again")
}

do {
  // A crossing macOS makes through the real overlap lands proportionally,
  // keeping the part of the step that ran along the seam: the step crossed
  // at y 1002, which maps to 1351.5, and went on 2 points further down.
  let bridge = Bridge([big, small])
  expectNone(bridge.handle(location: Point(x: 2558, y: 1000), delta: Point(x: 4, y: 4), time: 0), "approach")
  expect(bridge.handle(location: Point(x: 2562, y: 1004), delta: Point(x: 4, y: 4), time: 0.01), 2562, 1353.5, "cross")
  // Back the other way.
  expectNone(bridge.handle(location: Point(x: 2563, y: 1350), delta: Point(x: -1, y: 0), time: 0.02), "settle")
  expect(bridge.handle(location: Point(x: 2559, y: 1350), delta: Point(x: -4, y: 0), time: 0.03), 2559, 1000, "back")
}

do {
  // Aligned displays of the same height map one to one: macOS's own
  // crossing is left alone.
  let bridge = Bridge([big, display(2, 2560, 0, 1920, 1440)])
  expectNone(bridge.handle(location: Point(x: 2558, y: 500), delta: Point(x: 4, y: 0), time: 0), "approach")
  expectNone(bridge.handle(location: Point(x: 2562, y: 500), delta: Point(x: 4, y: 0), time: 0.01), "cross")
  // Diagonally too (traced: a step of (81, -72) across such a seam was
  // pulled back 72 points along it).
  let side = Bridge([display(1, -1900, -1440, 2560, 1440), display(2, 660, -1440, 2560, 1440)])
  expectNone(side.handle(location: Point(x: 652.4, y: -645.9), delta: Point(x: 81, y: -72), time: 0), "approach")
  expectNone(side.handle(location: Point(x: 733.4, y: -717.9), delta: Point(x: 81, y: -72), time: 0.01), "diagonal")
}

do {
  // Traced: macOS still delivered events from before a warp, and they were
  // read as a step back across the seam, so the pointer was warped back.
  // The 32" above the internal display, as arranged when traced.
  let builtIn = display(1, 0, 0, 1512, 982)
  let wide = display(5, 660, -1440, 2560, 1440)
  let bridge = Bridge([builtIn, display(3, -1900, -1440, 2560, 1440), wide], dwell: 0.04)
  let down = Point(x: 0, y: 131)
  expectNone(bridge.handle(location: Point(x: 3219, y: -0.5), delta: down, time: 0), "push down")
  expect(bridge.handle(location: Point(x: 3219, y: -0.5), delta: down, time: 0.05), 1511, 1, "into internal")
  expectNone(bridge.handle(location: Point(x: 3219, y: -0.5), delta: down, time: 0.054), "queued before the warp")
  check(bridge.ignoredStale, "the queued event is reported as ignored")
  expectNone(bridge.handle(location: Point(x: 1511, y: 9), delta: Point(x: 0, y: 8), time: 0.06), "after the warp")
  check(!bridge.ignoredStale, "the first event at the target ends the wait")
  // If the warp never shows up, events count again once the wait is over.
  let lost = Bridge([builtIn, wide], dwell: 0.04, settle: 0.25)
  _ = lost.handle(location: Point(x: 3219, y: -0.5), delta: down, time: 0)
  _ = lost.handle(location: Point(x: 3219, y: -0.5), delta: down, time: 0.05)
  _ = lost.handle(location: Point(x: 2000, y: -700), delta: down, time: 0.2)
  check(lost.ignoredStale, "far from the target inside the wait")
  _ = lost.handle(location: Point(x: 2000, y: -700), delta: down, time: 0.31)
  check(!lost.ignoredStale, "far from the target after the wait")
}

do {
  // One edge split between two neighbors, with dead stretches above, between
  // and below them: the edge is shared out by overlap, 600 to 540.
  let upper = display(2, 2560, 200, 1920, 600)
  let lower = display(3, 2560, 900, 1512, 982)
  let layout = Layout([big, upper, lower])
  let segs = layout.segments(of: 0, .right)
  check(segs.count == 2 && segs[0].neighbor == 1 && segs[1].neighbor == 2, "two segments in order")
  check(near(segs[0].hi, 1440 * 600 / 1140) && near(segs[1].lo, segs[0].hi) && near(segs[1].hi, 1440), "proportional")
  let a = layout.map(from: 0, .right, along: 100)!
  check(a.display == 1 && near(a.point.y, 279.1666666666667), "dead top -> upper")
  let b = layout.map(from: 0, .right, along: 850)!
  check(b.display == 2 && near(b.point.y, 1032.6003086419753), "dead gap -> lower")
  // Each neighbor's whole left edge belongs to the big display.
  let c = layout.map(from: 2, .left, along: 1391)!
  check(c.display == 0 && near(c.point.y, 1098.9473684210527), "lower's middle -> its share of big")
  // macOS carries the pointer into the upper display at y 780, which the
  // proportional split gives to the lower one: it is moved there.
  let bridge = Bridge([big, upper, lower])
  expectNone(bridge.handle(location: Point(x: 2558, y: 780), delta: Point(x: 4, y: 0), time: 0), "approach")
  let moved = bridge.handle(location: Point(x: 2562, y: 780), delta: Point(x: 4, y: 0), time: 0.01)
  check(moved.map { lower.frame.contains($0) } == true, "crossing re-routed to lower: \(String(describing: moved))")
}

do {
  // Stacked displays: the seam is horizontal.
  let top = display(1, 0, 0, 1000, 800)
  let below = display(2, 200, 800, 500, 400)
  let bridge = Bridge([top, below], dwell: 0.04)
  let down = Point(x: 0, y: 3)
  expectNone(bridge.handle(location: Point(x: 100, y: 799), delta: down, time: 0), "push down")
  expect(bridge.handle(location: Point(x: 100, y: 799), delta: down, time: 0.05), 250, 801, "into below")
  check(near(bridge.layout.map(from: 1, .top, along: 450)!.point.x, 500), "below's middle -> top's middle")
}

do {
  // Hotplug: a new layout replaces the old one and drops any push under way.
  let bridge = Bridge([big], dwell: 0.04)
  expectNone(bridge.handle(location: Point(x: 2559, y: 100), delta: push, time: 0), "alone")
  bridge.setDisplays([big, small])
  expectNone(bridge.handle(location: Point(x: 2559, y: 100), delta: push, time: 0.05), "fresh dwell")
  expect(bridge.handle(location: Point(x: 2559, y: 100), delta: push, time: 0.1), 2561, 675, "then warps")
  bridge.setDisplays([big])
  expectNone(bridge.handle(location: Point(x: 2559, y: 100), delta: push, time: 0.2), "unplugged")
  expectNone(bridge.handle(location: Point(x: 2559, y: 100), delta: push, time: 0.3), "unplugged, still")
  // A mode change keeps the display's id but resizes it: the new size is
  // what the edge maps onto (1440 tall onto 720, so y 100 lands at 650).
  bridge.setDisplays([big, display(2, 2560, 600, 1280, 720)])
  expectNone(bridge.handle(location: Point(x: 2559, y: 100), delta: push, time: 0.4), "new mode")
  expect(bridge.handle(location: Point(x: 2559, y: 100), delta: push, time: 0.45), 2561, 650, "new mode warps")
}

if failures > 0 {
  print("\(failures) failure(s)")
  exit(1)
}
print("all display-seams tests passed")
