// display-seams: join display edges that macOS leaves unjoined.
//
// macOS only lets the pointer cross between two displays where their edges
// overlap in System Settings > Displays > Arrange; the rest of the edge is a
// wall. This agent maps every edge onto its neighbors in proportion instead
// (see Seams.swift): pushing into the dead part of an edge for a moment warps
// the pointer to the matching point on the neighbor, and crossings through
// the real overlap are moved onto the same proportional mapping, so the
// whole height of one display meets the whole height of the next.
//
// The layout is reread whenever macOS reconfigures its displays: hotplug,
// rearrangement, resolution changes. Mirrored displays count once.
//
// It watches mouse movement through a global NSEvent monitor, which needs no
// grant, and moves the pointer by posting a mouse event, which needs
// Accessibility. Until that is granted it falls back to
// CGWarpMouseCursorPosition, after which macOS ignores the mouse for about a
// quarter of a second.
//
// A pointer captured by spicy in server mouse mode is recentred on every
// move, so it never stays against an edge long enough to be warped.
import AppKit
import ApplicationServices
import Foundation

func report(_ message: String) {
  FileHandle.standardError.write("display-seams: \(message)\n".data(using: .utf8)!)
}

func activeDisplays() -> [Display] {
  var count: UInt32 = 0
  guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
  var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
  guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
  return ids.prefix(Int(count))
    .filter { CGDisplayMirrorsDisplay($0) == kCGNullDirectDisplay }
    .map { id in
      let b = CGDisplayBounds(id)
      return Display(
        id: id,
        frame: Rect(
          x: Double(b.origin.x), y: Double(b.origin.y),
          width: Double(b.size.width), height: Double(b.size.height)))
    }
}

let bridge = Bridge(activeDisplays())

// macOS calls back once per display for each change, also when nothing that
// matters here moved. Reread every time; start the bridge over only when the
// layout changed.
CGDisplayRegisterReconfigurationCallback(
  { _, flags, _ in
    guard !flags.contains(.beginConfigurationFlag) else { return }
    let displays = activeDisplays()
    if displays != bridge.layout.displays { bridge.setDisplays(displays) }
  }, nil)

// Posted events carry this source, and a source's suppression interval is
// how long macOS ignores the hardware after one of its events: none.
let eventSource = CGEventSource(stateID: .hidSystemState)
eventSource?.localEventsSuppressionInterval = 0

// Move the pointer to `target` as a mouse event of the kind under way (a
// drag stays a drag).
func move(to target: Point) {
  let point = CGPoint(x: target.x, y: target.y)
  let buttons = NSEvent.pressedMouseButtons
  let (type, button): (CGEventType, CGMouseButton) =
    buttons & 1 != 0
    ? (.leftMouseDragged, .left)
    : buttons & 2 != 0
      ? (.rightMouseDragged, .right)
      : buttons != 0 ? (.otherMouseDragged, .center) : (.mouseMoved, .left)
  if AXIsProcessTrusted(),
    let event = CGEvent(
      mouseEventSource: eventSource, mouseType: type, mouseCursorPosition: point, mouseButton: button)
  {
    event.post(tap: .cghidEventTap)
    return
  }
  CGWarpMouseCursorPosition(point)
  CGAssociateMouseAndMouseCursorPosition(1)
}

// Ask for Accessibility up front, as shotedit does.
let axOpts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
if !AXIsProcessTrustedWithOptions(axOpts) {
  report("grant Accessibility in System Settings; until then the pointer freezes briefly after each jump")
}

// Report the grant for provisioning: once trusted, write this binary's path
// to ~/.local/state/display-seams/trusted-binary. TCC keys the grant to the
// binary, so a stale path there means the current build still needs one.
// Until then, recheck every few seconds; the grant applies without a restart.
func recordTrust() -> Bool {
  guard AXIsProcessTrusted(), let exe = Bundle.main.executablePath else { return false }
  let dir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".local/state/display-seams", isDirectory: true)
  try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  try? (exe + "\n").write(to: dir.appendingPathComponent("trusted-binary"), atomically: true, encoding: .utf8)
  return true
}
if !recordTrust() {
  Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { timer in
    if recordTrust() { timer.invalidate() }
  }
}

let motion: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
let monitor = NSEvent.addGlobalMonitorForEvents(matching: motion) { event in
  guard let cg = event.cgEvent else { return }
  let location = Point(x: Double(cg.location.x), y: Double(cg.location.y))
  let delta = Point(
    x: cg.getDoubleValueField(.mouseEventDeltaX),
    y: cg.getDoubleValueField(.mouseEventDeltaY))
  if let target = bridge.handle(location: location, delta: delta, time: event.timestamp) {
    move(to: target)
  }
}
guard monitor != nil else {
  report("could not install the mouse monitor")
  exit(1)
}

NSApplication.shared.setActivationPolicy(.prohibited)
NSApplication.shared.run()
