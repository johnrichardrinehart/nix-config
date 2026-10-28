// `keyboard-remap agent`: the device remaps in the user's session, the menu
// bar item that pauses and resumes all remapping, and the keys swallowed
// while a given app is frontmost.
//
// A session event tap sees each key after the device remaps and before any
// app does. Dropping events there needs Accessibility, which TCC keys to the
// binary; the Mac host runs a signed copy at a fixed path
// (darwin-configurations/mbp-host/signed-copies.nix), so the grant survives
// rebuilds. Until the grant arrives it checks every few seconds and installs
// the tap then; no restart is needed.
import AppKit
import ApplicationServices
import Foundation

private var filter: KeyFilter!
private var tap: CFMachPort?
private var paused = isPaused

private func log(_ message: String) {
  FileHandle.standardError.write("keyboard-remap: \(message)\n".data(using: .utf8)!)
}

/// The frontmost app. Its executable comes from the process, not the
/// bundle, so unbundled programs such as QEMU have one too.
private func frontmostApp() -> App? {
  guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
  var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))  // PROC_PIDPATHINFO_MAXSIZE
  let length = proc_pidpath(app.processIdentifier, &buffer, UInt32(buffer.count))
  return App(
    executablePath: length > 0 ? String(cString: buffer) : nil,
    bundleIdentifier: app.bundleIdentifier)
}

private let callback: CGEventTapCallBack = { _, type, event, _ in
  switch type {
  case .tapDisabledByTimeout, .tapDisabledByUserInput:
    if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
  case .keyDown, .keyUp:
    // While paused, presses pass; a release still pairs with a press
    // swallowed before the pause.
    if paused && type == .keyDown { break }
    let keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
    if filter.drop(
      down: type == .keyDown, keyCode: keyCode, flags: event.flags.rawValue, frontmost: frontmostApp)
    {
      return nil
    }
  default:
    break
  }
  return Unmanaged.passUnretained(event)
}

/// Report the grant for provisioning: write this binary's path to
/// ~/.local/state/keyboard-remap/trusted-binary. TCC keys the grant to the
/// binary, so a stale path there means the current build still needs one.
private func recordTrust() {
  guard let exe = Bundle.main.executablePath else { return }
  let dir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".local/state/keyboard-remap", isDirectory: true)
  try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  try? (exe + "\n").write(
    to: dir.appendingPathComponent("trusted-binary"), atomically: true, encoding: .utf8)
}

private func installTap() -> Bool {
  guard AXIsProcessTrusted() else { return false }
  let mask = CGEventMask(1 << CGEventType.keyDown.rawValue | 1 << CGEventType.keyUp.rawValue)
  guard
    let port = CGEvent.tapCreate(
      tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
      eventsOfInterest: mask, callback: callback, userInfo: nil)
  else { return false }
  tap = port
  CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, port, 0), .commonModes)
  CGEvent.tapEnable(tap: port, enable: true)
  recordTrust()
  return true
}

/// Menu bar item: a keyboard symbol, dimmed while paused, with one toggle.
private final class StatusItem: NSObject {
  let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
  let toggle = NSMenuItem(title: "", action: #selector(flip), keyEquivalent: "")

  override init() {
    super.init()
    item.button?.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "keyboard-remap")
    toggle.target = self
    let menu = NSMenu()
    menu.addItem(toggle)
    item.menu = menu
    update()
  }

  @objc func flip() { setPaused(!paused) }

  func update() {
    paused = isPaused
    item.button?.appearsDisabled = paused
    item.button?.toolTip = paused ? "Keyboard remapping paused" : "Keyboard remapping active"
    toggle.title = paused ? "Resume Keyboard Remapping" : "Pause Keyboard Remapping"
  }
}

func runAgent(_ config: Config) -> Never {
  let rules = config.apps
  do {
    filter = try KeyFilter(rules)
  } catch {
    log("invalid app rule: \(error)")
    exit(1)
  }

  NSApplication.shared.setActivationPolicy(.accessory)
  startDeviceRemapping(config.devices)
  let status = StatusItem()
  onPauseChange { status.update() }

  if !rules.isEmpty {
    let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    if !AXIsProcessTrustedWithOptions(prompt) {
      log("grant Accessibility in System Settings; until then no keys are swallowed")
    }
    if !installTap() {
      Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { timer in
        if installTap() { timer.invalidate() }
      }
    }
  }
  NSApplication.shared.run()
  exit(0)
}
