// Tells Glance when to look for a face, for the two cases that Glance
// cannot detect itself:
//
// 1. The screen locks after inactivity. Glance cannot tell this lock from a
//    lock by a key combination or a menu: both post com.apple.screenIsLocked.
//    With its "On lock" trigger off, Glance only looks for a face on a wake
//    or on the space key. When the screen locks, this agent measures the time
//    since the last keyboard or mouse event. A lock from a key combination or
//    a menu comes less than a second after an event; an inactivity lock comes
//    after the screensaver idle time.
//
// 2. A key or a mouse button is pressed while the screen is locked. Glance
//    reads the space key through IOHIDManager, but while the password field
//    on the lock screen has focus, macOS gives no keyboard or mouse HID
//    events to user processes. The idle times of the HID system per event
//    type still decrease at each press (in steps of about 0.5 s while
//    locked). The key itself is not known, so any key starts a scan.
//
// For both, the agent posts com.apple.screensaver.didstop, which Glance takes
// as a wake.
//
// Glance must have its unlock animation off and its "On lock" trigger off.
// Otherwise it arms at the lock, and it ignores a wake for 2 s after that.
//
// Usage: glance-trigger [minimum idle seconds for an inactivity lock, default 60]

import CoreGraphics
import Foundation

let minimumIdleSeconds = CommandLine.arguments.dropFirst().first.flatMap(Double.init) ?? 60

// Glance ignores a wake less than 2 s after it armed for the previous wake
// (it treats them as one wake burst). It arms 0.3 s after a wake and handles
// a wake 0.3 s after it, so 2 s after the previous wake is enough; 0.1 s more
// is margin.
let armBurstSeconds = 2.1

let center = DistributedNotificationCenter.default()

func log(_ message: String) {
    FileHandle.standardError.write(Data("\(Date()) \(message)\n".utf8))
}

func screenIsLocked() -> Bool {
    guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
    return session["CGSSessionScreenIsLocked"] as? Bool ?? false
}

func secondsSince(_ type: CGEventType) -> Double {
    CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: type)
}

// kCGAnyInputEventType: the most recent event of any type.
let anyInputEvent = CGEventType(rawValue: ~0)!

var lastWakeSent = Date.distantPast
var wakePending = false

func sendWake(_ reason: String) {
    guard screenIsLocked() else { return }
    center.postNotificationName(
        .init("com.apple.screensaver.didstop"), object: nil, userInfo: nil, deliverImmediately: true)
    lastWakeSent = Date()
    log("\(reason): Glance told to look for a face")
}

// Glance would ignore a wake inside its burst window, so a press there sends
// the wake when the window ends.
func sendWakeAfterBurst(_ reason: String) {
    // A wake that is already waiting covers this press too.
    guard !wakePending else { return }
    let wait = armBurstSeconds - Date().timeIntervalSince(lastWakeSent)
    guard wait > 0 else {
        sendWake(reason)
        return
    }
    wakePending = true
    DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
        wakePending = false
        sendWake(reason)
    }
}

// Polls the key-down and mouse-down idle times while the screen is locked. A
// decrease is a new press.
let pressTypes: [(type: CGEventType, name: String)] = [
    (.keyDown, "key press"),
    (.leftMouseDown, "click"),
    (.rightMouseDown, "right click"),
]
var pressPoll: Timer?
var lastPressIdle: [Double] = []

func startPressPoll() {
    pressPoll?.invalidate()
    // The key-down idle time at the lock includes the key combination that
    // locked the screen; only presses after this count.
    lastPressIdle = pressTypes.map { secondsSince($0.type) }
    pressPoll = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { timer in
        guard screenIsLocked() else {
            timer.invalidate()
            return
        }
        let idle = pressTypes.map { secondsSince($0.type) }
        defer { lastPressIdle = idle }
        guard let pressed = idle.indices.first(where: { idle[$0] < lastPressIdle[$0] }) else { return }
        sendWakeAfterBurst("\(pressTypes[pressed].name) while locked")
    }
}

_ = center.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { _ in
    let idle = secondsSince(anyInputEvent)
    startPressPoll()
    guard idle >= minimumIdleSeconds else {
        log(String(format: "lock after %.1f s idle: user lock, Glance waits for a key press, a click or a wake", idle))
        return
    }
    sendWakeAfterBurst(String(format: "lock after %.1f s idle (inactivity lock)", idle))
}

log("waiting for screen locks; inactivity lock = \(minimumIdleSeconds) s idle or more")
RunLoop.main.run()
