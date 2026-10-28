// keyboard-remap: per-keyboard key remaps and per-app key rules for macOS,
// without a driver extension (which device management may forbid).
//
//   keyboard-remap devices CONFIG   per-keyboard key remaps (root daemon)
//   keyboard-remap apps CONFIG      menu bar item and per-app rules (user agent)
//   keyboard-remap pause|resume     switch all remapping off or on
//   keyboard-remap status           print "paused" or "active"
//
// CONFIG is the JSON file the nix-darwin module writes (Rules.swift: Config).
import Foundation

let usage = "usage: keyboard-remap (devices|apps) CONFIG | pause | resume | status\n"
let arguments = CommandLine.arguments

switch (arguments.count, arguments.count > 1 ? arguments[1] : "") {
case (2, "pause"):
  setPaused(true)
case (2, "resume"):
  setPaused(false)
case (2, "status"):
  print(isPaused ? "paused" : "active")
case (3, "devices"), (3, "apps"):
  let config: Config
  do {
    config = try Config.load(arguments[2])
  } catch {
    FileHandle.standardError.write(
      "keyboard-remap: cannot read \(arguments[2]): \(error)\n".data(using: .utf8)!)
    exit(1)
  }
  if arguments[1] == "devices" { runDevices(config.devices) } else { runApps(config.apps) }
default:
  FileHandle.standardError.write(usage.data(using: .utf8)!)
  exit(2)
}
