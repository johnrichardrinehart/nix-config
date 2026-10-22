{
  lib,
  buildGo126Module,
  fetchFromGitHub,
  fetchurl,
  git,
  go_1_26,
  openssh,
  tmux,
}:
let
  # go.mod requires go >= 1.26.9; nixpkgs ships 1.26.8.
  go = go_1_26.overrideAttrs (
    finalAttrs: _old: {
      version = "1.26.10";
      src = fetchurl {
        url = "https://go.dev/dl/go${finalAttrs.version}.src.tar.gz";
        hash = "sha256-/WPog7ovK/ypPBZGsx6+9j4rHk0rMXyXidl2po2B828=";
      };
    }
  );
in
(buildGo126Module.override { inherit go; }) rec {
  pname = "agent-deck";
  version = "1.16.30";

  src = fetchFromGitHub {
    owner = "asheshgoplani";
    repo = "agent-deck";
    rev = "v${version}";
    hash = "sha256-3mVmpV5F1LqN/f5pbihR9Lrw/UO4nu2+/cldcE/UoB4=";
  };

  vendorHash = "sha256-v3vhZiTTktjmWuv4FTWAEiHaeSUXyVRVTOL02UeZZrw=";

  subPackages = [ "cmd/agent-deck" ];

  nativeCheckInputs = [
    git
    openssh
    tmux
  ];
  checkFlags = [
    # Keep the rest of the package tests enabled while skipping sandbox-sensitive
    # remote-execution, interactive TUI timing, fake-codex and fake-claude pane
    # process, PATH-restricted model probe, and `#!/bin/bash` stub-script checks.
    "-skip=TestRemoteCommandParity|TestRemoteSuccessfulMutationParity|TestCloseSessionWindow_KillsExtraWindow|TestLogCgroupIsolationDecision_WiredIntoBootstrap/tui_startup_emits_line|TestPerf_ColdStart_(Help|Version)|TestStatusStale_CLI_CandidateViewAndMutatesNothing|TestIssue2388_CapabilitiesCarryProbe|TestCodexAcceptanceGuardAcceptsFreshComposerThread|TestIssue2394_HydratePrefersLiveThreadOverGuessedPaneIdentity|TestIssue2400_ArchiveKeepsLiveCodexIdentity|TestIssue2396_FirstTurnOutputIsBoundToItsConversation|TestIssue2549_(SendAdoptsRotatedLiveThread|PeerOwnedLiveThreadIsNotAdopted|SubagentLiveThreadIsNotAdopted)|TestSessionSendSocketWaitPeerReply|TestLaunchSubagentScript_(AppendsFanoutHintOnlyWithoutIdentityBlock|FanoutHintNoDuplicate)"
    # The cmd/agent-deck tests start real tmux servers and run longer than the
    # default 10-minute go test timeout on the Nix builders.
    "-timeout=30m"
  ];

  preCheck = ''
    export TMPDIR=/tmp/agent-deck-tests
    export HOME="$TMPDIR/home"
    # Nix builders have variable startup latency. Use the multiplier that
    # upstream applies in CI while retaining the performance regression tests.
    export PERF_BUDGET_MULTIPLIER=2.0
    mkdir -p "$TMPDIR"
    mkdir -p "$HOME"
  '';

  meta = with lib; {
    description = "Your AI agent command center - manage multiple AI coding agents from one terminal";
    homepage = "https://github.com/asheshgoplani/agent-deck";
    license = licenses.mit;
    mainProgram = "agent-deck";
    maintainers = [ ];
  };
}
