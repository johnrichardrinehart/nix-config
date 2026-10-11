{
  bash,
  context-mode,
  lib,
  nix,
  nodejs,
  python3,
  writeShellApplication,
}:
let
  pluginSet = {
    inherit context-mode;
  };
  pluginPath = plugin: "${plugin}/lib/node_modules/${lib.getName plugin}";
  pluginRuntimeInputs =
    plugins: lib.unique (lib.concatMap (plugin: plugin.ompRuntimeInputs or [ ]) plugins);
  makeOmp =
    plugins:
    let
      runtimeInputs = [
        bash
        nix
        nodejs
        python3
      ]
      ++ pluginRuntimeInputs plugins
      ++ plugins;
    in
    (writeShellApplication {
      name = "omp";
      inherit runtimeInputs;
      # Runs the current llm-agents.nix omp, resolved at start-up.
      text = ''
        exec nix --tarball-ttl 86400 run github:numtide/llm-agents.nix#omp -- ${
          lib.escapeShellArgs (
            lib.concatMap (plugin: [
              "--extension"
              (pluginPath plugin)
            ]) plugins
          )
        } "$@"
      '';

      meta = {
        description = "Shell wrapper that runs OMP through llm-agents.nix";
        license = lib.licenses.mit;
        mainProgram = "omp";
        maintainers = [ ];
        platforms = lib.platforms.linux ++ lib.platforms.darwin;
      };
    }).overrideAttrs
      (old: {
        passthru = (old.passthru or { }) // {
          inherit plugins runtimeInputs;
          pluginRuntimeInputs = pluginRuntimeInputs plugins;
          withPlugins = select: makeOmp (lib.unique (plugins ++ select pluginSet));
        };
      });
in
makeOmp [ ]
