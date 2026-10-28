// The pause switch, shared by the agents and the command line: a
// notifyd state value (0 = active, 1 = paused) plus a notification on each
// change. notifyd keeps the value only while some process holds the name;
// the agents do, so it survives one of them restarting, but a reboot
// resumes remapping. Any local user may set it; pausing only gives
// the keyboards their own layout back.
import Foundation
import notify

let pauseName = "dev.johnrinehart.keyboard-remap.paused"

private let pauseToken: Int32 = {
  var token: Int32 = 0
  notify_register_check(pauseName, &token)
  return token
}()

var isPaused: Bool {
  var state: UInt64 = 0
  notify_get_state(pauseToken, &state)
  return state != 0
}

func setPaused(_ paused: Bool) {
  notify_set_state(pauseToken, paused ? 1 : 0)
  notify_post(pauseName)
}

/// Runs `handler` on the main queue after every change of the switch.
func onPauseChange(_ handler: @escaping () -> Void) {
  var token: Int32 = 0
  notify_register_dispatch(pauseName, &token, DispatchQueue.main) { _ in handler() }
}
