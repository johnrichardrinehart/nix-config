{
  lib,
  bash,
  buildGo126Module,
  coreutils,
  fetchFromGitHub,
  git,
  ncurses,
  openssh,
  tmux,
}:
buildGo126Module rec {
  pname = "agent-deck";
  version = "1.16.38";

  src = fetchFromGitHub {
    owner = "asheshgoplani";
    repo = "agent-deck";
    rev = "v${version}";
    hash = "sha256-fvJaRcWtaFKdFbyPJOYKU95gerpeWL819Ol0e8Y7c8k=";
  };

  vendorHash = "sha256-8d56v5csbdGaQku2LR7Twy2fKoXBVPKN9KPHdsithjg=";
  patches = [
    # Keep the full leak test when the inherited Nix build environment is too
    # large for tmux's command buffer.
    ../patches/agent-deck-test-tmux-command-file.patch
  ];

  # Test helpers deliberately use the production FHS-only vault PATH and an
  # env-based shebang, so nativeCheckInputs are invisible in Nix sandboxes.
  # Keep their behavioral tests active with explicit store paths.
  postPatch = ''
    substituteInPlace cmd/agent-deck/ask_cmd_test.go \
      --replace-fail "env >>" "${coreutils}/bin/env >>" \
      --replace-fail "| tr '/' '_'" "| ${coreutils}/bin/tr '/' '_'" \
      --replace-fail "cat >" "${coreutils}/bin/cat >"
    substituteInPlace tests/eval/harness/tmux_shim.go \
      --replace-fail "#!/usr/bin/env bash" "#!${bash}/bin/bash"
  '';

  subPackages = [ "cmd/agent-deck" ];

  nativeCheckInputs = [
    git
    ncurses
    openssh
    tmux
  ];
  checkFlags = [
    # Keep the rest of the package tests enabled while skipping sandbox-sensitive
    # remote-execution, interactive TUI timing, fake-codex and fake-claude pane
    # process, full-suite tmux reconciliation races, PATH-restricted model
    # probes, and `#!/bin/bash` stub-script checks. The Azure provider tests
    # exec the embedded `#!/usr/bin/env bash` provider script, which the
    # sandbox cannot run. The heartbeat behavior is
    # exercised separately as a focused package check. Issue2921's fake-claude
    # fixture skips without python3 and the parent test then fails.
    "-skip=TestRemoteCommandParity|TestRemoteSuccessfulMutationParity|TestCloseSessionWindow_KillsExtraWindow|TestLogCgroupIsolationDecision_WiredIntoBootstrap/tui_startup_emits_line|TestPerf_ColdStart_(Help|Version)|TestStatusStale_CLI_CandidateViewAndMutatesNothing|TestIssue2388_CapabilitiesCarryProbe|TestCodexAcceptanceGuardAcceptsFreshComposerThread|TestIssue2394_HydratePrefersLiveThreadOverGuessedPaneIdentity|TestIssue2400_ArchiveKeepsLiveCodexIdentity|TestIssue2396_FirstTurnOutputIsBoundToItsConversation|TestIssue2549_(SendAdoptsRotatedLiveThread|PeerOwnedLiveThreadIsNotAdopted|SubagentLiveThreadIsNotAdopted)|TestSessionSendSocketWaitPeerReply|TestLaunchSubagentScript_(AppendsFanoutHintOnlyWithoutIdentityBlock|FanoutHintNoDuplicate)|TestConductorHeartbeatTickCLIReadsInboxAndRules|TestIssue2921ClaudeLikeFakeIsGoneWhenItsCleanupReturns|TestProviderConnectAzure_"
    # The cmd/agent-deck tests start real tmux servers and run longer than the
    # default 10-minute go test timeout on the Nix builders.
    "-timeout=30m"
  ];

  preCheck = ''
    # Keep tmux's Unix socket below sockaddr_un's path limit.
    export TMPDIR=/tmp/ad
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
