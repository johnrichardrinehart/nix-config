// Makes Glance look for a face when the screen locks after inactivity, but
// not when the user locks it on purpose.
//
// Glance cannot tell the two locks apart: both post com.apple.screenIsLocked.
// With its "On lock" trigger off, Glance only looks for a face on wake or on
// the space key. This agent measures the time since the last keyboard or
// mouse event when the screen locks. A lock from a key combination or a menu
// comes less than a second after an event; an inactivity lock comes after the
// screensaver idle time. After an inactivity lock, the agent posts
// com.apple.screensaver.didstop, which Glance takes as a wake.
//
// Usage: glance-idle-trigger [minimum idle seconds, default 60]

import CoreGraphics
import Foundation

let minimumIdleSeconds = CommandLine.arguments.dropFirst().first.flatMap(Double.init) ?? 60

// Glance ignores a wake less than 2 s after it armed for the lock (it
// treats them as one wake burst). It arms about 0.3 s after the lock.
let wakeDelaySeconds = 2.5

let center = DistributedNotificationCenter.default()

func log(_ message: String) {
    FileHandle.standardError.write(Data("\(Date()) \(message)\n".utf8))
}

func screenIsLocked() -> Bool {
    guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
    return session["CGSSessionScreenIsLocked"] as? Bool ?? false
}

// kCGAnyInputEventType: the most recent event of any type.
let anyInputEvent = CGEventType(rawValue: ~0)!

_ = center.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { _ in
    let idle = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: anyInputEvent)
    guard idle >= minimumIdleSeconds else {
        log(String(format: "lock after %.1f s idle: user lock, Glance waits for a wake or the space key", idle))
        return
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + wakeDelaySeconds) {
        guard screenIsLocked() else { return }
        center.postNotificationName(
            .init("com.apple.screensaver.didstop"), object: nil, userInfo: nil, deliverImmediately: true)
        log(String(format: "lock after %.1f s idle: inactivity lock, Glance told to look for a face", idle))
    }
}

log("waiting for screen locks; inactivity lock = \(minimumIdleSeconds) s idle or more")
RunLoop.main.run()
