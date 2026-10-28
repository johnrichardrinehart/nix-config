// Device remaps: keeps each keyboard's UserKeyMapping (the property
// `hidutil property --set` writes) as the device remaps declare.
//
// The HID event system applies the mapping to the keyboard's events before
// anything else sees them, so it holds in secure input fields and needs no
// driver or privacy grant. Only a mapping set from within the login session
// that uses the keyboard takes effect: one set by a launch daemon, outside
// any session, reads back but changes nothing. So the per-user agent sets it
// in the user's session (`keyboard-remap agent`), and an agent in the login
// window session sets it there (`keyboard-remap devices`). It lives in the
// event system's service, not in the device, so it is set again whenever a
// keyboard service appears (attach, reconnect) and whenever the console user
// changes.
import Foundation
import IOKit
import IOKit.hid
import IOKit.hidsystem
import SystemConfiguration

private let userKeyMappingKey = "UserKeyMapping"

private func log(_ message: String) {
  FileHandle.standardError.write("keyboard-remap: \(message)\n".data(using: .utf8)!)
}

private final class DeviceRemapper {
  let remaps: [DeviceRemap]
  let client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)

  init(_ remaps: [DeviceRemap]) { self.remaps = remaps }

  /// The services the HID event system knows, by registry ID.
  func services() -> [UInt64: IOHIDServiceClient] {
    let services = (IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient]) ?? []
    var result: [UInt64: IOHIDServiceClient] = [:]
    for service in services {
      if let id = (IOHIDServiceClientGetRegistryID(service) as? NSNumber)?.uint64Value {
        result[id] = service
      }
    }
    return result
  }

  /// Sets UserKeyMapping on every keyboard whose mapping differs from the
  /// declared one, or from none while paused.
  func apply() {
    for (id, service) in services()
    where IOHIDServiceClientConformsTo(
      service, UInt32(kHIDPage_GenericDesktop), UInt32(kHIDUsage_GD_Keyboard)) != 0
    {
      let property = { (key: String) in IOHIDServiceClientCopyProperty(service, key as CFString) as Any? }
      let want = isPaused ? [] : userKeyMapping(remaps, property)
      let have =
        (property(userKeyMappingKey) as? [[String: NSNumber]])?.map { $0.mapValues(\.uint64Value) } ?? []
      if have == want { continue }
      let name = "\(property("Product") as? String ?? "keyboard") (registry 0x\(String(id, radix: 16)))"
      if IOHIDServiceClientSetProperty(service, userKeyMappingKey as CFString, want as CFArray) {
        log("set \(want.count) key mappings on \(name)")
      } else {
        log("could not set UserKeyMapping on \(name)")
      }
    }
  }

  /// IOKit announces a service before the HID event system has a client
  /// for it. Retry until every new service has one, for up to 10 seconds.
  func applyWhenPresent(_ ids: Set<UInt64>, attempt: Int = 0) {
    let missing = ids.subtracting(services().keys)
    if missing.count < ids.count { apply() }
    if !missing.isEmpty && attempt < 40 {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
        self.applyWhenPresent(missing, attempt: attempt + 1)
      }
    }
  }
}

/// Registry IDs of the services an IOKit iterator yields, draining it (IOKit
/// only notifies again once the iterator is drained).
private func drain(_ iterator: io_iterator_t) -> Set<UInt64> {
  var ids: Set<UInt64> = []
  var service = IOIteratorNext(iterator)
  while service != 0 {
    var id: UInt64 = 0
    if IORegistryEntryGetRegistryEntryID(service, &id) == KERN_SUCCESS { ids.insert(id) }
    IOObjectRelease(service)
    service = IOIteratorNext(iterator)
  }
  return ids
}

// Kept for the life of the process: IOKit and SystemConfiguration stop
// notifying once these are released.
private var notificationPort: IONotificationPortRef?
private var consoleUserStore: SCDynamicStore?

/// Applies the remaps now and on every keyboard arrival, console user change
/// and pause switch, from the main run loop the caller runs.
func startDeviceRemapping(_ remaps: [DeviceRemap]) {
  let remapper = DeviceRemapper(remaps)
  let context = Unmanaged.passRetained(remapper).toOpaque()

  // New HID services: keyboards attached or reconnected after start.
  let port = IONotificationPortCreate(kIOMainPortDefault)
  notificationPort = port
  CFRunLoopAddSource(
    CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .defaultMode)
  var iterator: io_iterator_t = 0
  let added: IOServiceMatchingCallback = { context, iterator in
    let remapper = Unmanaged<DeviceRemapper>.fromOpaque(context!).takeUnretainedValue()
    remapper.applyWhenPresent(drain(iterator))
  }
  let status = IOServiceAddMatchingNotification(
    port, kIOFirstMatchNotification, IOServiceMatching("IOHIDEventService"), added, context, &iterator)
  if status != KERN_SUCCESS {
    log("cannot watch for new keyboards (IOKit error \(status))")
    exit(1)
  }
  _ = drain(iterator)

  // A login or logout: set the mappings again in case the new session
  // changed them.
  var storeContext = SCDynamicStoreContext(
    version: 0, info: context, retain: nil, release: nil, copyDescription: nil)
  let consoleUserChanged: SCDynamicStoreCallBack = { _, _, context in
    Unmanaged<DeviceRemapper>.fromOpaque(context!).takeUnretainedValue().apply()
  }
  guard
    let store = SCDynamicStoreCreate(nil, "keyboard-remap" as CFString, consoleUserChanged, &storeContext),
    SCDynamicStoreSetNotificationKeys(store, [SCDynamicStoreKeyCreateConsoleUser(nil)] as CFArray, nil),
    let source = SCDynamicStoreCreateRunLoopSource(nil, store, 0)
  else {
    log("cannot watch for logins")
    exit(1)
  }
  CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
  consoleUserStore = store

  // The menu bar item or `keyboard-remap pause|resume`.
  onPauseChange {
    log(isPaused ? "paused" : "resumed")
    remapper.apply()
  }

  remapper.apply()
}

/// `keyboard-remap devices`: device remaps alone, for the login window.
func runDevices(_ remaps: [DeviceRemap]) -> Never {
  startDeviceRemapping(remaps)
  CFRunLoopRun()
  exit(0)
}
