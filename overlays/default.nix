inputs: {
  default =
    final: prev:
    let
      inherit (inputs.nixpkgs) lib;
      packageRoot = ../packages;
      packageEntries = builtins.readDir packageRoot;
      packageFiles = lib.filterAttrs (
        name: type: type == "regular" && lib.hasSuffix ".nix" name && name != "default.nix"
      ) packageEntries;
      packageDirs = lib.filterAttrs (
        name: type: type == "directory" && builtins.pathExists (packageRoot + "/${name}/default.nix")
      ) packageEntries;
      packagePaths =
        lib.mapAttrs' (
          name: _: lib.nameValuePair (lib.removeSuffix ".nix" name) (packageRoot + "/${name}")
        ) packageFiles
        // lib.mapAttrs (name: _: packageRoot + "/${name}") packageDirs;
      packageArgs = {
        brightness-sync.brightness-notify = johnPkgs.brightness-notify;
        clipboard-store-notify.cliphist = johnPkgs.cliphist-master;
        clipboard-watch.clipboard-store-notify = johnPkgs.clipboard-store-notify;
        cliphist-master.cliphist = prev.cliphist;
        cliphist-picker.cliphist = johnPkgs.cliphist-master;
        codex-config-merged = {
          name = "codex-config-merged.toml";
          layers = [ ];
          header = final.writeText "codex-config-merged-empty-header.toml" "";
        };
        codex-omx-layer.oh-my-codex = johnPkgs.oh-my-codex;
        confirm-ssh-activity-before-suspend.promptTimeoutSeconds = 15 * 60;
        display-layout = {
          inherit (inputs) display-layout;
          system = final.stdenv.hostPlatform.system;
        };
        droidcam-v4l2loopback.kernel = final.linuxPackages_latest.kernel;
        git-meld = {
          inherit (inputs) git-meld;
          system = final.stdenv.hostPlatform.system;
        };
        kitkat-rs-faster = {
          inherit (inputs) kitkat-rs;
          system = final.stdenv.hostPlatform.system;
        };
        kitkat-rs-fastest = {
          inherit (inputs) kitkat-rs;
          system = final.stdenv.hostPlatform.system;
        };
        kitkat-rs-low-rss = {
          inherit (inputs) kitkat-rs;
          system = final.stdenv.hostPlatform.system;
        };
        framework-ec-flash = {
          inherit (johnPkgs) framework-ec;
          frameworkTool = final.framework-tool;
        };
        fuzzel-dmenu = {
          fuzzel = johnPkgs.fuzzel_1_15_0;
          inherit (final) niri;
        };
        fuzzel_1_15_0.fuzzel = prev.fuzzel;
        kill-idle-group.onIdlePackage = johnPkgs.on-idle;
        libmoonshine = {
          diarizationModels = johnPkgs.moonshine-diarization-models;
          onnxruntime = johnPkgs.onnxruntime-openvino;
          inherit (johnPkgs) openvino;
        };
        lock-idle-ssh-sessions = {
          idleTimeoutSeconds = 5 * 60;
          terminalMultiplexer = "tmux";
          inherit (johnPkgs) tmux;
        };
        ssh-session.tmux = johnPkgs.tmux;
        monstar = {
          inherit (inputs) monstar;
          system = final.stdenv.hostPlatform.system;
        };
        moonshine-models-onnx = {
          inherit (final) python3;
          modelDir = johnPkgs.moonshine-models-source;
        };
        moonshine-voice = {
          inherit (johnPkgs) libmoonshine;
        };
        nebula.nebula = prev.nebula;
        niri-cycle-display-mode = {
          fuzzel = johnPkgs.fuzzel_1_15_0;
          inherit (final) niri;
        };
        niri-gather-windows.niri = final.niri;
        niri-screenshot = {
          fuzzel = johnPkgs.fuzzel_1_15_0;
          inherit (final) niri;
          inherit (johnPkgs) wormhole-send;
        };
        omx-agent-tools = {
          inherit (johnPkgs) codex-cli-nix;
          inherit (johnPkgs) oh-my-codex;
        };
        omp.context-mode = johnPkgs.context-mode;
        on-idle.idleTimeoutSeconds = 5 * 60;
        onnxruntime-openvino.openvino = johnPkgs.openvino;
        repo-manager = {
          inherit (inputs) repo-manager;
          system = final.stdenv.hostPlatform.system;
        };
        repod = {
          inherit (inputs) repo-manager;
          system = final.stdenv.hostPlatform.system;
        };
        whisper-voice-type = {
          moonshineVoice = johnPkgs.moonshine-voice;
          model = johnPkgs.moonshine-models-onnx;
        };
        tmux.tmux = prev.tmux;
        util-linux.util-linux = prev.util-linux;
      };
      johnPkgs = lib.mapAttrs (
        name: path: final.callPackage path (packageArgs.${name} or { })
      ) packagePaths;
    in
    {
      dev = (prev.dev or { }) // {
        johnrinehart = johnPkgs;
      };
    };
}
