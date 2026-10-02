# nixosModules

Reusable JohnOS NixOS modules, overlays, packages, Home Manager modules, and
supporting assets.

This repository is intended to be consumed as a flake input by host/system
configuration repositories. It exposes:

- `lib`
- `nixosModules.default`
- `overlays.default`
- per-system `packages`
- per-system `legacyPackages`

The companion host configuration repository is
[`nixosConfigurations`](https://github.com/johnrichardrinehart/nixosConfigurations).

## Nebula and Mycelium

`nixosModules.nebula` imports `nixos-modules/nebula/default.nix`.
Generic DNS and registry modules live in that directory.
Mycelium policy lives in `nixos-modules/nebula/mycelium/`.
`nixosModules.mycelium` imports only Mycelium and its generic dependencies.

Configure native networks through `services.nebula.networks.<name>`.
Configure per-link DNS through `dev.johnrinehart.nebula.networks.<name>.dns`:
set `enable`, `server`, and `domains`. Each network retains its own DNS routes.
The generic modules do not select certificate groups, revocations, or TLS trust.

Enable `dev.johnrinehart.mycelium.enable` and set `ca`, `cert`, and `key`.
The default role is `peer`. Set `role = "lighthouse"` for the registry host.
Mycelium configures discovery, relays, certificate groups, firewall rules,
revocations, and the private DNS zones.
Use `firewall.inbound` for host ports and `firewall.peerSshPorts` for outbound SSH.
Set `firewall.allowPeerHTTPS = true` to permit HTTPS to other peers.

Enabled Mycelium hosts trust the bundled public TLS CA by default:

```nix
dev.johnrinehart.mycelium.trustCA = {
  enable = true;
  bundle = ./mycelium-tls-ca.crt;
};
```

Omit this assignment to use `nebula/mycelium/mycelium-tls-ca.crt`.
Set `trustCA.enable = false` to exclude this module's CA from system trust.
Independent `security.pki.certificateFiles` entries remain unchanged.
The TLS CA differs from the Nebula CA supplied through `ca`.
Never put private CA keys in the module bundle.

`dev.johnrinehart.nebula.registry` tracks lighthouse peers and serves private
DNS and a status page for each overlay. Configure its `parentDomain`,
`networks`, and `acme` credentials. Configure additional private zones through
each network's `aliases`. Callers configure their own Nebula admission rules.
The page updates its counts and peer rows every second without a page reload.
The registry poll interval controls when new Nebula observations become available.

Mycelium serves peers as `<peer>.mycelium.nebula.johnrinehart.dev` and
`<peer>.mycelium.internal`. Peers route both zones to the lighthouse.
Use `mycelium.registry` to configure its console port, upstream resolvers, and ACME credentials.

### HTTP server certificates

Enable `serverTLS` on each Mycelium HTTP server:

```nix
dev.johnrinehart.mycelium.serverTLS = {
  enable = true;
  name = "web";
  group = "nginx";
};
```

Set `name` to the host's Nebula certificate name.
The module exposes `hostName = "<name>.mycelium.internal"`.
The default runtime files are `/var/lib/mycelium-tls/server.crt` and `server.key`.
Set `certFile` and `keyFile` to use existing deployment paths.
Set `group` to the HTTP service group that reads the private key.
The module maintains certificate mode `0444` and private key mode `0440`.

The lighthouse registry automatically selects this private certificate through SNI.
Its public hostname retains the ACME certificate.
The registry still identifies each caller from its overlay source address.
Missing configured certificates stop startup instead of disabling private HTTPS.

Other HTTP servers use the same certificate paths.
For Nginx, configure the application's private virtual host:

```nix
{ config, ... }:
let
  tls = config.dev.johnrinehart.mycelium.serverTLS;
in
{
  services.nginx.virtualHosts.${tls.hostName} = {
    onlySSL = true;
    sslCertificate = tls.certFile;
    sslCertificateKey = tls.keyFile;
    listen = [{ addr = "10.77.0.7"; port = 443; ssl = true; }];
    locations."/".proxyPass = "http://127.0.0.1:8080";
  };
}
```

Use the server's actual overlay address and application routes.
Permit TCP 443 in the host's existing Mycelium inbound policy.
Do not expose the private virtual host on a public interface.
Native HTTP servers can use `certFile` and `keyFile` without an Nginx proxy.

Issue certificates on the deployment machine:

```console
nix run .#mycelium-tls -- CA_CERT CA_KEY web.mycelium.internal OUTPUT_DIRECTORY
```

Append additional DNS names after `OUTPUT_DIRECTORY` when the server needs aliases.
For an existing server, install its current key as `OUTPUT_DIRECTORY/server.key` before the first issuance.
The signer creates a separate ECDSA P-256 server key and a server certificate valid for 365 days.
It verifies each DNS name before replacing the certificate.
Repeated issuance preserves the existing server key.
Failed issuance preserves the existing certificate.

Keep `CA_KEY` only on the deployment machine, outside Git and the Nix store.
Install only `server.crt` and `server.key` on the HTTP server.
Create their parent directory with access for the configured HTTP service group.
Renew before the certificate expires.
Repeat the signer command with the same output directory to retain the server key.
Restart the HTTP service after certificate installation or renewal.
Clients must trust the Mycelium TLS CA.


## SSH tmux sessions

The laptop profile starts each interactive SSH shell in a new tmux session.
Each session receives the tmux user option `@ssh-session=1`.
The option remains set when the user renames the session.

Start a session with an initial human-readable name:

```console
$ ssh -t john@$HOST ssh-session new project-name
```

Start a direct login shell without tmux:

```console
$ ssh -t john@$HOST ssh-session shell
```

This command does not create or attach a tmux session.

Rename it at any time without removing the option:

```console
$ tmux rename-session project-renamed
```

List SSH-created sessions and their stable handles:

```console
$ ssh john@$HOST ssh-session list
```

Attach to a session by its handle or exact current name:

```console
$ ssh -t john@$HOST ssh-session attach s14
$ ssh -t john@$HOST ssh-session attach project-name
```

`ssh-session attach` rejects unmarked sessions and never creates a replacement.
A plain interactive SSH login always creates a separate session.
The helper does not remove detached sessions automatically.

## Display breakpoint helper

Consumers can build custom daylight-display schedules with the exported helper:

```nix
let
  breakpoint = inputs.nixosModules.lib.daylightDisplay.breakpoint;
in
{
  dev.johnrinehart.desktop.daylightDisplay.breakpoints = [
    (breakpoint "sunrise" 45 95 6250)
    (breakpoint "sunset" (-15) 35 3750)
  ];
}
```

The arguments are the solar event, offset in minutes, brightness percentage,
and color temperature in kelvin.

## Brightness keys

`brightness-notify` (bound to the Niri brightness keys) moves a logical level
between 0 and 100% in 4% steps. At 60% and above, the hardware brightness
equals the level. Below 60%, the hardware brightness falls linearly to 24% at
level 4. Level 0 sets the hardware brightness to 0, so the screen is black. The
laptop backlight and external monitors' DDC/CI brightness (VCP `0x10`) follow
the hardware brightness. A software factor on every output equals the hardware
brightness divided by 60%, so software does more of the dimming the lower you
go.

The factor is published at
`$XDG_RUNTIME_DIR/brightness-notify/software-brightness`. When
`daylightDisplay` is enabled, daylight-display multiplies it into its own
brightness and reapplies it immediately on `SIGUSR1`. Otherwise
`brightness-notify` sets it directly through `wl-gammarelay-rs`, if that is
running.

The `brightness-sync` user unit, enabled by
`dev.johnrinehart.desktop.displayBrightness.enable` (on by default in the laptop
profile, together with `hardware.i2c`), owns DDC/CI: `brightness-notify` signals it
(`SIGUSR1`) after each level change, and it rescans monitors with `ddcutil`
after DRM hotplug events (3 s and 15 s after the last event, to give monitors
behind DisplayPort MST time to answer). At login and after hotplug it also
reapplies the software factor. Monitors need DDC/CI enabled in their OSD, and
Dell's Auto Brightness should be off so it does not fight the written value.

## Git commit transfer

The `git-patch-wormhole` package transfers one or more Git heads over Magic
Wormhole. Each ZIP contains a Git bundle with the exact commit objects and the
metadata required to restore them. It is included when
`dev.johnrinehart.packages.shell.enable` is enabled.

Describe each head as `<base>:<branch>:<revision-range>`. The receiver creates
each named branch at the recorded base and fast-forwards it to the original
tip, preserving every commit hash:

```console
$ git patch-wormhole send main:feature:main..feature release:hotfix:release..hotfix
$ git patch-wormhole receive 7-example-code
```

The exact base commit must already exist in the receiving repository. Leave the
branch field empty to restore a detached head:

```console
$ git patch-wormhole send main::main..experiment
```

For a single head, pass a Git revision selection directly:

```console
$ git patch-wormhole send main..feature
```

It restores onto the current branch when that branch is at the original base.
`--branch` creates a named branch, while `--base` checks out an existing branch,
tag, or commit that must resolve to the original base:

```console
$ git patch-wormhole receive 7-example-code --branch feature --base main
```

A commit hash includes its parent hash, so moving commits to a different base
cannot preserve its identity. The tool is for exact repository synchronization
and intentionally rejects that operation.

The receiving worktree must be clean. Multi-head archives always restore their
recorded bases and branch names; they reject `--branch` and `--base`.

