---
name: nix-config-refresh
description: Refresh johnrichardrinehart/nix-config end to end — flake inputs, vendored package versions and hashes, maintained fork branches and the patch files generated from them — then build on the remote builders, smoke-test, verify, and commit. Use when asked to "update everything", "refresh packages", or "do the update again".
---

# nix-config refresh

Repo: `~/code/dev-worktrees/github.com/johnrichardrinehart/nix-config/main`.
Each pass is incremental: only change what moved upstream since the last pass. Repeat passes when builds took long enough for upstream to move.

## 0. Baseline
- `git status --short`. Note pre-existing unrelated edits (e.g. `nixos-modules/nix.nix`, iwlwifi/mt76 work) — never stage them.
- Builders: aim to have as many remote builders available as possible. Do not pin to one host. Gather candidates from both sources:
  - **Stock config (`framework` only):** `nixos-configurations/framework/tailscale-nix-builders.{nix,sh}` generates `~/.local/state/tailscale-nix-builders-user/machines`. A systemd user service refreshes it every 60 s (`systemctl --user start tailscale-nix-builders.service` refreshes it now). Other hosts use only the neocache list.
  - **neocache:** `~/code/dev-worktrees/git.sr.ht/~fuzzybear3965/neocache/main/scripts/verify-remote-builders.sh <out-file>` (wired up by that repo's `.envrc`). It discovers Connor's and Justin's shared Tailscale peers (Justin's machines use SSH user `john`, Connor's use `connorbaker`). Each peer gets a Tailscale ping, an SSH probe, and a 10 MiB transfer benchmark that must finish within 15 s; slow peers are dropped. The script writes a machines file with host keys. Log: `/tmp/neocache-verify-remote-builders.log`.
  - Run the neocache benchmark fresh before each heavy build. Merge both machines files, dedupe by host, and order them by the benchmark: peers that passed the benchmark just now come first, unbenchmarked peers after, and peers that failed the benchmark are dropped. Pass the result with `--builders @<merged-file>`.
  - There is no aarch64 builder unless neocache's `root@10.100.0.1` fallback is reachable.

## 1. Flake inputs
- **Reconsider the pinned release branches first.** `nix flake update` only moves inputs within the branch or tag they already pin. For each input in `flake.nix` that pins a release branch or tag (`nixpkgs?ref=nixos-YY.MM`, `home-manager-nixos` `release-YY.MM`, `nix-darwin-YY.MM`, `lanzaboote/vX.Y.Z`, and any others), check whether upstream has published a newer stable release (`git ls-remote --heads`/`--tags`). If it has:
  - Move every input that follows that release together (nixpkgs, home-manager, and nix-darwin share `YY.MM`).
  - Rebase the self-managed forks onto the new release and rename their branches to match (e.g. the home-manager fork `release-YY.MM-overwrite-backup-rm-f`). Update the `url`s and the comments that explain them.
  - Read the release notes for removed or renamed options, then evaluate every host configuration.
  - Report the bump separately: it is a bigger change than a lock refresh. Ask before moving to a new release if anything breaks or needs non-trivial migration.
- Then run `nix flake update` in the repo root and in `dev/`.
- Bootstrap ISO in `flake.nix` (`bootstrapIso`): bump to the newest `nixos-unstable` aarch64 minimal ISO; prefetch its hash.

## 2. Vendored packages
Check upstream (GitHub `releases/latest`, npm `latest`, `go.dev/VERSION?m=text`, `git ls-remote` for branch heads) against:

| File | Upstream |
|---|---|
| `packages/agent-deck.nix` | asheshgoplani/agent-deck (also its Go toolchain override) |
| `packages/droidcam-v4l2loopback.nix` | dev47apps/droidcam-linux-client |
| `packages/onnxruntime-openvino/default.nix`, `packages/openvino.nix` | microsoft/onnxruntime, openvinotoolkit/openvino |
| `packages/nebula.nix` | slackhq/nebula (needs `buildGo127Module` while go.mod requires Go 1.27) |
| `packages/oh-my-codex.nix` | Yeachan-Heo/oh-my-codex tag → rebased fork branch (step 3) |
| `packages/context-mode/default.nix` | npm `context-mode` |
| tmux, herdr, impala, util-linux, git-local-namespace, cliphist-master, kdlfmt, libmoonshine, mighty-mitts | their upstreams |

This table is not exhaustive. Each pass, also scan `packages/`, `overlays/`, `nixos-modules/`, and `nixos-configurations/` for `version =`, `rev =`, `tag =`, `fetchurl`, `fetchFromGitHub`, and `fetchpatch` pins, and check every pin you find against its upstream.

Hash workflow: source hash via `nix store prefetch-file --json --unpack <archive-url>`; vendor/npm/cargo hashes by setting `sha256-AAAA…=` (fakeHash), building locally with `--builders ''`, and copying the `got:` hash.
Known gotchas: `gh` is not on PATH in sandboxes — use `fetch` against api.github.com; ctx_batch_execute shells choke on `for` loops — one command per entry.

## 3. Maintained branches and patches
Rebase, verify, push with an explicit lease (`--force-with-lease=refs/heads/<b>:<old-sha>`; plain `--force-with-lease` reports stale info), then regenerate artifacts:

**Reconsider the release line for every self-managed package, not just its tip.** Each fork or patch stack tracks some upstream line: a release branch, a stable tag series, `main`/`master`, or a version that nixpkgs ships. For each one, ask whether that line is still the right target:
- Has upstream cut a newer release branch or major version? Examples: GTK `gtk-3-24` vs a newer stable branch; the Nix patch's target version vs what `nix.package` now uses (e.g. `nix_2_35`); Niri `main` vs a new tagged release that already contains our patches; the home-manager fork's `release-YY.MM`.
- Has a patch been merged upstream? Then drop it rather than rebasing it again.
- Would the package be better on a different line? For example, follow a stable tag instead of `main` once one includes the fixes we need, or the reverse.
- When the target line changes, rebase onto it, rename any versioned branch (e.g. `dev/hook-runtime-hardening-v<ver>`), and update the Nix comments that name the line.
- This covers every self-managed package in the repository, including ones not listed below. To find them, look for `fetchFromGitHub` with `owner = "johnrichardrinehart"`, fork URLs in `flake.nix`, and files under `patches/` and `nixos-modules/**/*.patch`.

- **Smithay** `smithay/drm-scanner-newly-mapped` (branch `fix/drm-scanner-newly-mapped-events`) onto `origin/master`, push to `fork`.
- **Niri** `niri-wm/niri/nix-config-patches` onto `origin/main` (not master). If Smithay moved, edit both revs in `Cargo.toml`, `nix develop -c cargo --config net.git-fetch-with-cli=true update -p smithay`, `git commit --fixup <pin commit>` + autosquash. Regenerate `nixos-modules/desktop/0000…0004-*.patch` with `git format-patch --no-numbered -1 --stdout <commit>` per commit. Update `niriRevision`, source hash, and cargo vendor hash in `nixos-modules/desktop/greetd+niri.nix`.
- **Niri fork branches** `software-egl-opt-in`, `overview-active-output` (on github.com/johnrichardrinehart/niri; use a temp worktree from the bare clone). Update the commit URL + `fetchpatch2` hash in `nixos-configurations/mbp-apple-silicon/niri-software-egl.nix` (compute with `nix build --impure --expr` calling `fetchpatch2` with `lib.fakeHash`). `per-input-keyboard` is local-only.
- **oh-my-codex** `oh-my-codex/update-packages` (HEAD is a repo-manager fork ref) onto the release tag commit; push to `fork` as `dev/hook-runtime-hardening` and `dev/hook-runtime-hardening-v<ver>`; update version/rev/src hash/npmDepsHash.
- **Nix** `nixos/nix/darwin-optimise-skip-unlinkable-files` onto `origin/master`, push to `fork`; refresh `patches/nix-optimise-skip-unlinkable-app-bundle-files.patch` only if it no longer applies with zero fuzz.
- **Monstar** stacks → `patches/monstar-*.patch`.
- **GTK Quartz** (`gitlab.gnome.org/johnrichardrinehart/gtk/quartz-mrs`): rebase every `quartz-*` branch onto `origin/gtk-3-24` (NOT `main` — wrong base produces thousands of conflicts). Push needs GitLab HTTPS credentials; usually unavailable — report.
- **spice-gtk**: rebase onto `origin/master`; same credential caveat.
- **home-manager** fork `release-26.05-overwrite-backup-rm-f` when upstream release branch moves.

## 4. Build and smoke
- Heavy builds (OpenVINO/ONNX, Niri): use every available remote builder from the merged machines file (step 0), with the best benchmarked peers first:
  `nix build --no-link --max-jobs 0 --option builders-use-substitutes true --builders @<merged-machines-file> .#<attr>`
  Raise each line's max-jobs field (the 4th field, e.g. `4`) to the host's `nproc` when it is known (check with `ssh <host> nproc`), so single big derivations get all the cores. `--max-jobs 0` keeps the build off the local machine.
  Partial builds cannot be resumed, so never cancel a long build to switch hosts.
- Smokes: `nix run .#nebula -- -version`, `nix run .#oh-my-codex -- --version`, `nix run .#nixosConfigurations.framework.config.programs.niri.package -- --version` (must list all five patches), ONNX via `OrtGetApiBase()->GetVersionString()`.
- Apple Silicon Niri cannot be built (aarch64): instead apply the software-EGL patches + `0000–0004` with `patch --fuzz=0` onto a temp Niri worktree and `cargo check` inside `nix develop`.
- oh-my-codex full `npm test` has ~12 FHS-path failures on NixOS (ps/mkdir/sleep missing); not regressions. Needs `nix shell nixpkgs#gcc`.

## 5. Verify
- `nix fmt -- --ci` (expect 0 changed).
- `nix --no-eval-cache flake check --no-build`. If it fails with `path '…-source.drv' is not valid`, auto-GC collected an IFD source drv: re-instantiate (`nix path-info --derivation <attr>.src`) and rerun — not a regression.
- `git diff --check -- . ':(exclude)**/*.patch'`.

## 6. Commit / push (only when asked)
Group commits; stage paths explicitly, never `-a`:
1. `flake: update inputs and the bootstrap ISO` — `flake.lock dev/flake.lock flake.nix`
2. `packages: update <names>` — package files + new patches
3. `niri: follow main and refresh the downstream patches` — `greetd+niri.nix`, `0000–0004`, `niri-software-egl.nix`
4. `patches: rebase the monstar and nix patches`
On push rejection: `git fetch`, confirm incoming commits touch none of our files, `git rebase --autostash origin/main`, rerun flake check, push.

## Report
Per pass, report:
- what moved (old → new)
- release-line decisions: for each flake input and self-managed package, whether it stayed on its release branch or tag series or moved to a newer one, and why
- what was rechecked and found unchanged
- the commands run and their results
- blockers (GitLab pushes, aarch64 builds, local-only branches)
