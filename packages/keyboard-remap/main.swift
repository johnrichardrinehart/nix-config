// keyboard-remap: per-keyboard key remaps and per-app key rules for macOS,
// without a driver extension (which device management may forbid).
//
//   keyboard-remap devices CONFIG   per-keyboard key remaps (root daemon)
//   keyboard-remap apps CONFIG      keys swallowed in given apps (user agent)
//
// CONFIG is the JSON file the nix-darwin module writes (Rules.swift: Config).
import Foundation

let usage = "usage: keyboard-remap (devices|apps) CONFIG\n"
let arguments = CommandLine.arguments
guard arguments.count == 3, ["devices", "apps"].contains(arguments[1]) else {
  FileHandle.standardError.write(usage.data(using: .utf8)!)
  exit(2)
}

let config: Config
do {
  config = try Config.load(arguments[2])
} catch {
  FileHandle.standardError.write("keyboard-remap: cannot read \(arguments[2]): \(error)\n".data(using: .utf8)!)
  exit(1)
}

if arguments[1] == "devices" {
  runDevices(config.devices)
} else {
  runApps(config.apps)
}
