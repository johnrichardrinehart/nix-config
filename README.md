# nix-config

Unified JohnOS NixOS and nix-darwin configurations, reusable modules,
overlays, packages, Home Manager modules, and supporting assets.

The flake exposes:

- `nixosConfigurations` for managed NixOS hosts
- `darwinConfigurations.mbp-host`
- reusable `nixosModules` and `darwinModules`
- `overlays.default`
- per-system `packages` and `legacyPackages`
- `apps.aarch64-darwin`
- shared `lib` functions

Managed NixOS hosts:

- `framework`
- `gce`
- `hp_spectre_x360`
- `mbp-apple-silicon`
- `mbp-apple-silicon-bootstrap`
- `mbp-intel-silicon`
- `nebula-lighthouse`
- `rock5c-nas`
- `thinkpad_w510`
- `virtualbox`

## Mac host (`darwinConfigurations.mbp-host`)

The Apple Silicon MacBook Pro that runs the `mbp-apple-silicon` guest is managed
with nix-darwin and Home Manager from `darwin-configurations/mbp-host`: shell
(zsh, direnv + nix-direnv, zoxide as `j`, the NixOS hosts' oh-my-posh prompt),
Git and SSH identity, Terminal.app's "Clear Dark" profile, the FiraMono Nerd
Font, macOS defaults (Dock placement, input sources, scrolling, appearance), Karabiner
and spicy config, the VM share table, `shotedit` (Cmd+Shift+4 straight into
the screenshot editor), and the GUI apps Karabiner-Elements and KeePassXC.

The VM launcher's SPICE viewer is `Spicy.app`, which Home Manager copies into
`~/Applications/Home Manager Apps`; the launcher runs that copy when it matches
its own build. As a bundled app it keeps its Dock and app-switcher entry across
Dock restarts, and "Keep in Dock" pins a path that survives rebuilds.

The VM share table (`dev.johnrinehart.mbp-host.vmShares`, in
`darwin-configurations/mbp-host/vm-shares.nix`) lists directories shared with
the guest over NFSv3, each exported by the side its data lives on:
`source = "guest"` (the default) is exported by the guest and mounted here by
the launcher; `source = "host"` is exported by this Mac's nfsd, which
`provision-mac` configures (`/etc/exports`, `/etc/nfs.conf`, mountd pinned to
20048), and mounted by the guest's `vm-host-shares.service`. The guest reaches
that nfsd through a socat relay the launcher runs on `MBP_APPLE_VM_HOST_NFS_PORT`
(2227), because macOS nfsd never closes its end of a connection the client
closes first, and the guest's hard mount would wait on that connection forever.
The table becomes `~/guest-vm-fs-mappings.json`, which the launcher reads at
every start.

The apps are installed from the vendors' own signed release files, pinned by
hash in `darwin-configurations/mbp-host/apps.nix`, rather than from nixpkgs'
repackaged bundles, which lose the vendor's code signature (and with it
Keychain access and permission grants). An app is installed when missing or
older than declared; one that updated itself is not downgraded.

```bash
nix run .#provision-mac
```

On a fresh Mac, install Nix first with the official multi-user installer
(`sh <(curl -L https://nixos.org/nix/install)`; nix-darwin takes over its
daemon in place), then run it straight from GitHub, with flakes enabled for
this one command:

```bash
nix --extra-experimental-features 'nix-command flakes' \
  run github:johnrichardrinehart/nix-config#provision-mac
```

Run it as the primary user; it asks for sudo. It builds the system, retires
the hand-made setup it replaces (moving existing files aside as
`*.before-nix-darwin` / `*.before-home-manager`), and activates. Run it again
to apply later changes.

Some steps macOS only accepts from the user: approving Karabiner's background
items, driver extension, Input Monitoring and Accessibility, Accessibility for
`shotedit` (again after every rebuild of it), and putting the SSH keys in
place. Modules declare these under `dev.johnrinehart.provisionMac.manualSteps`
with a check for each; after activating, `provision-mac` lists the ones still
pending, launches the app that asks for them, and opens System Settings at
the first. Once everything is done it only prints "no manual steps pending".

Downstream flakes extend the host with
`lib.mkMbpHost { modules = [ ... ]; }` and expose a matching provisioner with
`lib.mkProvisionMac` (the app) and `lib.mkProvisionMacPackage` (the same
provisioner as a package, so `nix build .#provision-mac` builds it without
running it). Per-user additions go under `home-manager.users.john`.

## Framework share mount

Framework mounts the `john` account's Nextcloud files at `~/share` through
WebDAV. The server stores these files in an encrypted B2 bucket.
The mount starts after the network becomes ready and reconnects after failures.
Writes use a local cache with a 4 GiB target and an 8 GiB free-space reserve.
The dedicated Nextcloud app password resides in `secrets/share-webdav.yaml`.
sops-nix decrypts the password into a systemd credential at service start.
Use `systemctl status rclone-share.service` to inspect mount health.

## Framework Bluetooth

Framework disables the Bluetooth idle timer so keyboards can reconnect after sleep.
BlueZ automatically enables the adapter through `[Policy] AutoEnable=true`.
Framework does not power-cycle the adapter during resume.

## SliceMK firmware

On Linux or macOS, update the SliceMK ErgoDox 202207 Green left half:

```console
nix run .#slicemk-update
```

The app prints preparation instructions and waits for Enter in an interactive terminal.
Connect only the left half by USB.
With the keys facing up and USB-C facing you, press the right reset button twice within 500 ms.
The green LEDs indicate bootloader mode.
The app uses `sudo` when it must mount the drive or obtain write access.
On macOS, the app finds the drive with `diskutil` and `ioreg` and needs no `sudo`.
macOS can report that the disk was not ejected properly when the bootloader restarts.
Ignore that message.
It checks the board ID before copying the firmware built from the current configuration.
Both halves report the same board ID, so the app cannot distinguish the left half from the right half.
Do not connect the right half in bootloader mode.
The bootloader can disconnect during the final filesystem sync.
For a disconnect error after copying, the app waits up to ten seconds for the same USB serial to return as a ZMK keyboard.
The app reports success only when that device returns.
Earlier write errors and unconfirmed disconnects remain failures.
After the transfer, test typing and hold Tab to check that Caps Lock stays unchanged.
This update does not clear saved Bluetooth pairings.
Do not hold Fn or clear Bluetooth profiles during the update.

`packages/slicemk-update/keyboard.json` contains the dongleless configuration.
`packages/slicemk-update/dongle.json` contains the separate dongle configuration.
Both configurations use native Dvorak, plain Tab, and three Bluetooth host profiles.
The mouse layer moves the pointer at up to 3200 counts per second.
It reaches that speed on a quadratic ramp over 350 ms, so short presses stay precise.
The inner column of small keys in the right thumb cluster selects the profiles.
The top key selects profile 0 for the work machine.
The middle key selects profile 1 for Framie.
The bottom key selects profile 2 for the phone.
Hold Fn and tap the middle key to toggle the QWERTY overlay.
The separate Caps Lock key remains available.
On the right half, the key immediately right of L sends `/`.
Hold Shift for `?`.
The key immediately right of S sends `-`.
On the left half, the key immediately right of 5 sends Delete.
The QWERTY overlay retains Delete on its top letter row and apostrophe on its home row.
The left half controls Bluetooth profiles and USB/Bluetooth output in dongleless mode.
No dongle is required.
The app installs only the custom left-half firmware.
It does not flash the right half or dongle.
Changing between dongle and dongleless roles requires the documented firmware and bond-reset procedure.

Hold Fn and tap USB Output to toggle host Bluetooth.
USB Output is the inner key of the upper pair of small keys in the left thumb cluster.
Host Bluetooth Off stops host advertising and disconnects phones and computers.
It preserves the wireless split link and all saved pairings.
USB typing remains available.
Select a host profile before enabling host Bluetooth to choose the reconnection target.
Profile selection and Bluetooth Output do not enable host Bluetooth while it is off.
The keyboard enables host Bluetooth after reboot.

The firmware uses the public SliceMK ZMK source and the local host-only Bluetooth patch.
`packages/slicemk-update/firmware.nix` pins the firmware sources, Zephyr modules, and build tools.
`render-keymap.py` generates the devicetree keymap directly from each JSON configuration.
After editing a JSON configuration, rebuild the firmware:

```console
nix build .#slicemk-firmware
# result/zmk.uf2 is the left-half firmware.
nix build .#slicemk-dongle-firmware
# result/zmk.uf2 is the dongle firmware.
```

The vendor configurator cannot build the custom host Bluetooth commands.
Use [SliceMK's firmware guide](https://docs.slicemk.com/firmware/zmk/wireless/guide/) for hardware and role changes.

## Framework voice dictation

`framework` uses converted ONNX Moonshine models with OpenVINO. The
`nix-config` packages `libmoonshine` and `moonshine-models-onnx` handle the
conversion and the session setup. Before switching the system, load the model
and transcribe an audio clip. The package's unit tests do not exercise model
inference.

The Pulse capture backend requests 100 ms recording latency and a 20 ms
processing interval. These settings are part of the pinned dictation package;
no runtime service override is needed. After switching, use the normal
RightCtrl leader and “start dictation” command to check first-text latency.
Leader-key monitoring also survives USB and Bluetooth keyboard reconnects;
there is no need to restart the service after changing keyboards.

## Nebula lighthouse installation

`nixosConfigurations.nebula-lighthouse` defines the x86_64 DigitalOcean
custom-image guest. Disko defines the disk layout in
`nixos-configurations/nebula-lighthouse/disko.nix`. The GPT disk has a 1 MiB
GRUB BIOS boot partition, a 2 GiB vfat `/boot`, and an ext4 root.
DigitalOcean custom images do not support UEFI or IPv6.

Build `.#nixosConfigurations.nebula-lighthouse.config.system.build.diskoImagesScript`
on an x86_64 Linux builder, then execute the script from a scratch directory.
It creates `main.raw` **in that directory**, not in the Nix store. The image
is an 8 GiB sparse BIOS-bootable NixOS disk. Compress it with
`gzip -c main.raw > main.img.gz` before upload. The intended
`s-1vcpu-2gb` Droplet has a 50 GiB disk. On first boot, NixOS grows the root
partition and ext4 filesystem to fill that disk. Do not run the destructive
Disko installer against an existing Droplet.

The guest uses IPv4 DHCP, the pinned DigitalOcean guest profile, and
cloud-init with ConfigDrive before DigitalOcean metadata. NixOS handles
network configuration and first-boot SSH host-key generation. Cloud-init
imports the Droplet's SSH public keys. It skips ConfigDrive's per-instance
scripts because DigitalOcean supplies an empty script and an Ubuntu-specific
machine-ID script. The `john@nixos` key remains authorized for root without
metadata, including local QEMU boots. The image contains no SSH host private
key or Nebula credentials. Test a disposable copy of `main.raw` with BIOS
firmware, not OVMF. Booting the upload image itself persists guest identity
in the template.

### The `mycelium` overlay

The Nebula network is named `mycelium` (tun device `nebula.mycelium`, unit
`nebula@mycelium`). Its CA only signs addresses in `10.77.0.0/24`. Hosts use
the `nix-config` `dev.johnrinehart.mycelium` module. The lighthouse sets
`role = "lighthouse"` to run the registry and relay.

Certificates carry the identity: the name becomes the host's DNS label and
the networks its overlay address. Every host except the lighthouse carries
the `peer` group. Hosts accept inbound traffic only from `peer`, so the
lighthouse can never open a connection to a host; contact always starts from
a host. The lighthouse's own outbound rules are empty as a second layer.
Discovery, hole punching and relaying are Nebula control traffic and are not
affected.

`framework` (`framie`, `10.77.0.2/24`) contacts the lighthouse at `10.77.0.1`
through `nebula-lighthouse.johnrinehart.dev:4242` from an ephemeral UDP port.
It accepts ICMP and TCP 22 from peers. It sends ICMP, HTTPS, and SSH on TCP
22, 2222, and 8022 to peers.
It sends DNS and HTTPS to the lighthouse. It answers punch notifications and
uses the lighthouse, also a Nebula relay, when a direct tunnel fails.

The module routes `mycelium.nebula.johnrinehart.dev` and `mycelium.internal`
to the lighthouse. Each peer is available as `<peer>.mycelium.internal`.
Enabled Mycelium hosts trust the module's public TLS CA by default.
Set `dev.johnrinehart.mycelium.trustCA.enable = false` to disable that trust.
Set `trustCA.bundle` to replace the public CA bundle.
Framework uses the default bundle. The lighthouse explicitly disables CA trust.
The module stores the public CA and revocations under `nixos-modules/nebula/mycelium/`.

### Peer registry, DNS and dashboard

The lighthouse polls its Nebula debug console (localhost only, keys
generated on the lighthouse under `/var/lib/nebula-console` and
`/var/lib/nebula-registry`) every 10 seconds and keeps every certificate it
has ever seen in `/var/lib/nebula-registry/registry.db`. A peer is online
while it has a tunnel to the lighthouse and goes offline after 30 seconds
without one; events (first seen, online, offline, address and certificate
changes) are kept for 365 days, peers forever.

DNS for `mycelium.nebula.johnrinehart.dev` comes from that history:
`<certificate name>.mycelium.nebula.johnrinehart.dev`, for example
`framework.mycelium.nebula.johnrinehart.dev` and
`lighthouse.mycelium.nebula.johnrinehart.dev`. It is served on `10.77.0.1:53`,
reachable only through Nebula. Hosts route both private Mycelium zones to
the lighthouse with systemd-resolved. Other names resolve as before.
Clients without split DNS send every lookup to `10.77.0.1`.
The registry forwards queries outside the overlay to `1.1.1.1` and then `9.9.9.9`.
The lighthouse and those resolvers see those queries.

`https://lighthouse.mycelium.internal/` and
`https://lighthouse.mycelium.nebula.johnrinehart.dev/` show peers inside the caller's certificate networks.
`/api/peers` returns the same view as JSON.
The registry identifies the caller from its source overlay address.

The private hostname uses `dev.johnrinehart.mycelium.serverTLS`.
Install its Mycelium-CA certificate at `/var/lib/mycelium-tls/server.crt`.
Install its separate server key at `/var/lib/mycelium-tls/server.key`, owned by root with group `nebula-registry` and mode `0440`.
Give that group access to the parent directory.
Use the reusable `mycelium-tls` signer from `packages/mycelium-tls`.
Keep the CA signing key on the deployment machine.
Restart `nebula-registry.service` after certificate renewal.

SNI selects the private certificate without replacing the public ACME identity.
The public certificate uses ACME DNS-01 through Cloudflare.
Install `CF_DNS_API_TOKEN=…` in `/var/lib/lighthouse-acme/cloudflare.env` with owner root and mode `0400`.
Then run `systemctl start acme-order-renew-lighthouse.mycelium.nebula.johnrinehart.dev`.

To add a host: sign a certificate with `-groups peer` and an address in
`10.77.0.0/24`. Deploy its credentials through `dev.johnrinehart.mycelium` and switch the host.
The host appears in the registry, DNS, and dashboard as soon as it connects.

### Credentials

`secrets/nebula-ca.yaml` contains the encrypted CA signing key.
`secrets/nebula-framework.yaml` contains the public CA certificate and
`framie`'s signed certificate and private key. Both files use the Framework
SSH host key as their only age recipient. The former administrator age
identity cannot decrypt either file. sops-nix installs only the Framework
node files under `/run/secrets` for Nebula. Never copy the CA signing key to
the lighthouse or mount it in the Nebula service. The lighthouse's own
certificate and key live in `/var/lib/nebula/` on the lighthouse only.

Old Git revisions remain encrypted to their original recipient. Rekeying
the current file does not revoke access to those revisions.

Keep a secure recovery copy of the Framework SSH host key. Without it,
neither current encrypted file can be decrypted. Before rotating that key,
re-encrypt both files to the new age recipient while the old key is
available. Verify decryption with the new key before retiring the old key.

To issue a new host certificate, decrypt the CA key as root on Framework
into a root-only tmpfs directory. Set `SOPS_AGE_KEY_CMD` to the absolute
`ssh-to-age` path followed by
`-private-key -i /etc/ssh/ssh_host_ed25519_key`. SOPS captures the native
age identity that the command writes to standard output. Do not copy the
SSH private key into the repository or a user directory. Use
`nebula-cert sign` with
`-ca-crt`, `-ca-key`, `-name`, `-networks <host-address>/24` and, for every
host except the lighthouse, `-groups peer`.
Verify the result with `nebula-cert verify`. Encrypt the new certificate
and host key before updating the configuration. Remove the plaintext files
from tmpfs. The CA signing key stays outside the runtime Nebula service.

On `framie`, build `.#nixosConfigurations.framework.config.system.build.toplevel`.
Switch with `sudo nixos-rebuild switch --flake .#framework` when root access
is available. Verify `nebula@mycelium.service`, `nebula.mycelium`, and a
connection to `10.77.0.1` before removing the imported DigitalOcean image.

The lighthouse holds only the public CA certificate and its own signed
certificate and private key under `/var/lib/nebula/`. Their modes are
`0640 root:nebula-mycelium`. Never put a host's private key or the CA key
in an unencrypted repository file. Before the CA expires, create a new CA
and sign new certificates for both hosts. Update the two encrypted files,
replace the lighthouse files through pinned SSH, and switch `framework`.
Verify peer connectivity before retiring the old CA.
