// Configuration and matching rules for keyboard-remap, free of IOKit,
// CoreGraphics and AppKit so the tests run without a window server.
import Foundation

/// The file both modes read. The nix-darwin module
/// (darwin-modules/keyboard-remap) writes it, translating key names into
/// HID usages and macOS key codes.
struct Config: Decodable {
  var devices: [DeviceRemap]
  var apps: [AppRule]

  static func load(_ path: String) throws -> Config {
    try JSONDecoder().decode(Config.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
  }
}

// MARK: - Devices

/// A value a HID service property must have, as `hidutil --matching` takes it.
enum PropertyValue: Decodable, Equatable {
  case bool(Bool)
  case int(Int64)
  case string(String)

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Int64.self) {
      self = .int(value)
    } else {
      self = .string(try container.decode(String.self))
    }
  }

  /// Whether a property, as the HID event system reports it, equals this
  /// value. CFBoolean and CFNumber both arrive as NSNumber; services report
  /// "Built-In" as either.
  func matches(_ property: Any?) -> Bool {
    switch self {
    case .bool(let want): return (property as? NSNumber)?.boolValue == want
    case .int(let want): return (property as? NSNumber)?.int64Value == want
    case .string(let want): return (property as? String) == want
    }
  }
}

/// Keys of the keyboards whose properties match, remapped below everything
/// else in macOS: the login window, secure input and every app see the new
/// keys.
struct DeviceRemap: Decodable {
  var description: String
  /// HID service properties a keyboard must have, e.g. `{"Built-In": true}`
  /// or `{"VendorID": 7504, "ProductID": 24926}`.
  var match: [String: PropertyValue]
  /// `[from, to]` usages on the keyboard/keypad page (0x07).
  var map: [[UInt32]]

  func matches(_ property: (String) -> Any?) -> Bool {
    match.allSatisfy { key, value in value.matches(property(key)) }
  }
}

let keyboardPage: UInt64 = 0x7_0000_0000

/// The `UserKeyMapping` a keyboard gets: the pairs of every remap it
/// matches, in order. Empty for keyboards no remap matches, so a keyboard
/// that stops matching loses its mapping.
func userKeyMapping(_ remaps: [DeviceRemap], _ property: (String) -> Any?) -> [[String: UInt64]] {
  remaps.filter { $0.matches(property) }.flatMap(\.map).map { pair in
    [
      "HIDKeyboardModifierMappingSrc": keyboardPage | UInt64(pair[0]),
      "HIDKeyboardModifierMappingDst": keyboardPage | UInt64(pair[1]),
    ]
  }
}

// MARK: - Apps

/// Modifiers as CGEventFlags carries them, side-independent. Fn is left
/// out: macOS sets its flag on arrow and function keys pressed alone.
enum Modifier: String, Decodable, CaseIterable {
  case capsLock = "caps_lock"
  case shift
  case control
  case option
  case command

  var flag: UInt64 {
    switch self {
    case .capsLock: return 0x1_0000  // maskAlphaShift
    case .shift: return 0x2_0000  // maskShift
    case .control: return 0x4_0000  // maskControl
    case .option: return 0x8_0000  // maskAlternate
    case .command: return 0x10_0000  // maskCommand
    }
  }

  static func held(_ flags: UInt64) -> Set<Modifier> {
    Set(allCases.filter { flags & $0.flag != 0 })
  }
}

/// Which app must be frontmost, by regular expressions on its executable's
/// path or its bundle identifier; either list matching is enough. With both
/// empty the rule applies in every app.
struct FrontmostApplication: Decodable {
  var filePaths: [String]
  var bundleIdentifiers: [String]
}

/// The app in front when a key arrives.
struct App {
  var executablePath: String?
  var bundleIdentifier: String?
}

/// A key swallowed while an app is frontmost: neither it, its repeats nor its
/// release reach any app. Keys are as apps see them, after device remaps.
struct AppRule: Decodable {
  var description: String
  var frontmostApplication: FrontmostApplication
  /// macOS virtual key code (kVK_*).
  var keyCode: UInt16
  /// All must be held.
  var mandatory: [Modifier]
  /// May be held too; any modifier in neither list stops the match.
  var optional: [Modifier]
  /// Every modifier may be held.
  var anyOptional: Bool
}

func regex(_ pattern: String) throws -> NSRegularExpression {
  try NSRegularExpression(pattern: pattern)
}

func search(_ patterns: [NSRegularExpression], _ text: String?) -> Bool {
  guard let text else { return false }
  let range = NSRange(text.startIndex..., in: text)
  return patterns.contains { $0.firstMatch(in: text, range: range) != nil }
}

/// The app rules with their expressions compiled, and the keys swallowed so
/// far. A key swallowed when pressed stays swallowed until released, even if
/// the modifiers or the frontmost app change meanwhile, so no app sees a
/// release (or repeat) without its press.
struct KeyFilter {
  struct Compiled {
    var rule: AppRule
    var filePaths: [NSRegularExpression]
    var bundleIdentifiers: [NSRegularExpression]

    func matches(keyCode: UInt16, flags: UInt64) -> Bool {
      guard keyCode == rule.keyCode else { return false }
      let held = Modifier.held(flags)
      let mandatory = Set(rule.mandatory)
      guard mandatory.isSubset(of: held) else { return false }
      return rule.anyOptional || held.isSubset(of: mandatory.union(rule.optional))
    }

    func matches(_ app: App?) -> Bool {
      if filePaths.isEmpty && bundleIdentifiers.isEmpty { return true }
      guard let app else { return false }
      return search(filePaths, app.executablePath)
        || search(bundleIdentifiers, app.bundleIdentifier)
    }
  }

  let rules: [Compiled]
  private(set) var swallowed: Set<UInt16> = []

  init(_ rules: [AppRule]) throws {
    self.rules = try rules.map { rule in
      Compiled(
        rule: rule,
        filePaths: try rule.frontmostApplication.filePaths.map(regex),
        bundleIdentifiers: try rule.frontmostApplication.bundleIdentifiers.map(regex))
    }
  }

  /// Whether to drop a key event. `frontmost` is only asked when a rule's
  /// key and modifiers match.
  mutating func drop(down: Bool, keyCode: UInt16, flags: UInt64, frontmost: () -> App?) -> Bool {
    if !down { return swallowed.remove(keyCode) != nil }
    if swallowed.contains(keyCode) { return true }
    let candidates = rules.filter { $0.matches(keyCode: keyCode, flags: flags) }
    if candidates.isEmpty { return false }
    let app = frontmost()
    guard candidates.contains(where: { $0.matches(app) }) else { return false }
    swallowed.insert(keyCode)
    return true
  }
}
