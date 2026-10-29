// Tests for Rules.swift, built together with it: swiftc Rules.swift tests/main.swift
import Foundation

var failures = 0

func check(_ ok: Bool, _ what: String, line: Int = #line) {
  if !ok {
    failures += 1
    print("FAIL line \(line): \(what)")
  }
}

let command: UInt64 = 0x10_0000
let shift: UInt64 = 0x2_0000
let capsLock: UInt64 = 0x1_0000
let kVK_ANSI_H: UInt16 = 0x04
let kVK_ANSI_J: UInt16 = 0x26

let qemu = App(
  executablePath: "/nix/store/0123456789abcdfghijklmnpqrsvwxyz-qemu-10.2.4/bin/.qemu-system-aarch64-wrapped",
  bundleIdentifier: nil)
let terminal = App(executablePath: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal",
  bundleIdentifier: "com.apple.Terminal")

// The configuration as the nix-darwin module writes it.
let json = """
  {
    "devices": [
      {"description": "built-in", "match": {"Built-In": true, "Transport": "FIFO"}, "map": [[30064771092, 30064771124], [30064771085, 30064771083]]},
      {"description": "by id", "match": {"VendorID": 7504}, "map": [[30064771181, 1095216660483]]}
    ],
    "apps": [
      {
        "description": "Cmd+H in QEMU",
        "frontmostApplication": {
          "filePaths": ["^/nix/store/[0-9a-df-np-sv-z]{32}-qemu-[0-9][^/]*/bin/(\\\\.qemu-system-aarch64-wrapped|qemu-system-aarch64)$"],
          "bundleIdentifiers": []
        },
        "keyCode": 4, "mandatory": ["command"], "optional": ["caps_lock"], "anyOptional": false
      },
      {
        "description": "Cmd+J anywhere, any modifiers",
        "frontmostApplication": {"filePaths": [], "bundleIdentifiers": []},
        "keyCode": 38, "mandatory": ["command"], "optional": [], "anyOptional": true
      }
    ]
  }
  """
let config = try! JSONDecoder().decode(Config.self, from: json.data(using: .utf8)!)

// Devices: properties as the HID event system reports them.
func properties(_ values: [String: Any]) -> (String) -> Any? { { values[$0] } }

let builtIn = properties(["Built-In": NSNumber(value: 1), "Transport": "FIFO", "VendorID": NSNumber(value: 0)])
let builtInBool = properties(["Built-In": kCFBooleanTrue as Any, "Transport": "FIFO"])
let external = properties(["Built-In": NSNumber(value: 0), "Transport": "FIFO", "VendorID": NSNumber(value: 7504)])
let unknown = properties([:])

check(config.devices[0].matches(builtIn), "Built-In reported as the number 1 matches true")
check(config.devices[0].matches(builtInBool), "Built-In reported as a boolean matches true")
check(!config.devices[0].matches(external), "Built-In 0 does not match true")
check(!config.devices[0].matches(unknown), "a missing property matches nothing")
check(!config.devices[0].matches(properties(["Built-In": NSNumber(value: 1), "Transport": "USB"])),
  "every property must match")
check(PropertyValue.bool(false).matches(NSNumber(value: 0)), "false matches 0")
check(!PropertyValue.bool(false).matches(nil), "false does not match a missing property")

let q = UInt64(0x7_0000_0014)
let quote = UInt64(0x7_0000_0034)
check(
  userKeyMapping(config.devices, builtIn) == [
    ["HIDKeyboardModifierMappingSrc": q, "HIDKeyboardModifierMappingDst": quote],
    ["HIDKeyboardModifierMappingSrc": 0x7_0000_000D, "HIDKeyboardModifierMappingDst": 0x7_0000_000B],
  ], "the matching remap's usages, in order")
check(
  userKeyMapping(config.devices, external) == [
    ["HIDKeyboardModifierMappingSrc": 0x7_0000_006D, "HIDKeyboardModifierMappingDst": 0xFF_0000_0003]
  ], "an external keyboard gets only its own remap; usages off the keyboard page pass unchanged")
check(userKeyMapping(config.devices, unknown).isEmpty, "a keyboard no remap matches gets an empty mapping")

// Apps.
var filter = try! KeyFilter(config.apps)
var asked = 0
func drop(_ down: Bool, _ key: UInt16, _ flags: UInt64, _ app: App?) -> Bool {
  filter.drop(down: down, keyCode: key, flags: flags, frontmost: { asked += 1; return app })
}

check(drop(true, kVK_ANSI_H, command, qemu), "Cmd+H in QEMU is swallowed")
check(drop(false, kVK_ANSI_H, command, qemu), "and so is its release")
check(!drop(false, kVK_ANSI_H, command, qemu), "a second release passes: only swallowed presses pair")
check(drop(true, kVK_ANSI_H, command | capsLock, qemu), "Caps Lock is optional")
_ = drop(false, kVK_ANSI_H, 0, qemu)
check(!drop(true, kVK_ANSI_H, command | shift, qemu), "Shift is neither mandatory nor optional")
check(!drop(true, kVK_ANSI_H, 0, qemu), "Command is mandatory")
check(!drop(true, kVK_ANSI_H, command, terminal), "other apps get Cmd+H")
check(!drop(true, kVK_ANSI_H, command, nil), "with no frontmost app the app condition fails")

asked = 0
_ = drop(true, 0x00, command, qemu)
check(asked == 0, "the frontmost app is only asked when key and modifiers match")

// A swallowed key stays swallowed until released, whatever changes meanwhile.
check(drop(true, kVK_ANSI_H, command, qemu), "press")
check(drop(true, kVK_ANSI_H, 0, terminal), "repeat after Command is let go and the app changes")
check(drop(false, kVK_ANSI_H, 0, terminal), "release")
check(!drop(true, kVK_ANSI_H, 0, terminal), "the next plain press passes")
_ = drop(false, kVK_ANSI_H, 0, terminal)

check(drop(true, kVK_ANSI_J, command | shift | capsLock, terminal), "any optional modifier, in any app")
_ = drop(false, kVK_ANSI_J, 0, terminal)
check(!drop(true, kVK_ANSI_J, shift, terminal), "mandatory modifiers still apply with any optional")

check((try? KeyFilter([AppRule(
  description: "bad", frontmostApplication: FrontmostApplication(filePaths: ["("], bundleIdentifiers: []),
  keyCode: 0, mandatory: [], optional: [], anyOptional: false)])) == nil,
  "an invalid expression is an error")

if failures > 0 {
  print("\(failures) failed")
  exit(1)
}
print("all passed")
