{
  description = "Unified JohnOS Nix configuration, modules, overlays, and packages";

  inputs = {
    flake-parts.url = "github:hercules-ci/flake-parts";

    nixpkgs.url = "github:NixOS/nixpkgs?ref=nixos-26.05";

    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    display-layout = {
      url = "github:johnrichardrinehart/display-layout";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    git-meld = {
      url = "github:johnrichardrinehart/git-meld";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    keepassxc-hybrid = {
      url = "github:johnrichardrinehart/keepassxc-hybrid";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    home-manager = {
      # release-26.05 plus nix-community/home-manager#10006, which master
      # contains (cf22324a2724) but release-26.05 does not.
      url = "github:johnrichardrinehart/home-manager/release-26.05-overwrite-backup-rm-f";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    home-manager-nixos = {
      url = "github:nix-community/home-manager/release-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    kitkat-rs = {
      url = "github:johnrichardrinehart/kitkat-rs";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    lanzaboote = {
      url = "github:nix-community/lanzaboote/v1.2.0";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Monstar builds with Zig 0.17, which nixos-26.05 does not have, so it
    # keeps its own nixpkgs.
    monstar.url = "github:rockorager/monstar";

    nix-darwin = {
      url = "github:nix-darwin/nix-darwin/nix-darwin-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nixos-generators = {
      url = "github:nix-community/nixos-generators";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nixos-hardware = {
      url = "github:NixOS/nixos-hardware";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # MixOS builds mainline Linux 7.3.5 and Zig from nixos-unstable, so it
    # keeps its own nixpkgs.
    nixos-uz801.url = "git+ssh://git@git.sr.ht/~fuzzybear3965/nixos-uz801";

    pam-biometrics = {
      url = "github:johnrichardrinehart/pam-biometrics";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    repo-manager = {
      url = "github:johnrichardrinehart/repo-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    rock5c-nixos = {
      url = "github:johnrichardrinehart/rock5c-nixos";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    sops-nix = {
      url = "github:mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{
      self,
      flake-parts,
      ...
    }:
    let
      systems = [
        "aarch64-darwin"
        "aarch64-linux"
        "x86_64-linux"
      ];
      inherit (inputs.nixpkgs) lib;

      moduleInputs = inputs // {
        home-manager = inputs.home-manager-nixos;
      };
      overlays = import ./overlays moduleInputs;
      reusableNixosModules = {
        default = import ./nixos-modules {
          inputs = moduleInputs;
          inherit lib;
        };
        # Part of `default`; needs overlays.default.
        bluez = ./nixos-modules/bluez.nix;
        mycelium = ./nixos-modules/nebula/mycelium;
        nebula = ./nixos-modules/nebula;
        # Not part of `default`: it replaces the root filesystem with RAM.
        netboot = ./nixos-modules/netboot;
      };
      unifiedLib = lib // {
        daylightDisplay = import ./lib/daylight-display.nix;
      };

      allowUnfreePackages =
        pkg:
        let
          name = lib.getName pkg;
        in
        # packages/media-seek-android builds with the Android SDK. Its
        # packages and archives all share androidenv's meta.homepage.
        (pkg.meta.homepage or null) == "https://developer.android.com/tools"
        || builtins.elem name [
          "arm-trusted-firmware-rk3588"
          "context-mode"
          "moonshine-models-source"
        ];
      mkPkgs =
        system: extraOverlays:
        import inputs.nixpkgs {
          inherit system;
          overlays = [ overlays.default ] ++ extraOverlays;
          config.allowUnfreePredicate = allowUnfreePackages;
        };
      pkgsBySystem = lib.genAttrs systems (system: mkPkgs system [ ]);
      reusablePackages = lib.mapAttrs (_: pkgs: import ./packages { inherit pkgs; }) pkgsBySystem;
      slicemkApps = lib.genAttrs [ "aarch64-darwin" "aarch64-linux" "x86_64-linux" ] (
        system:
        let
          package = pkgsBySystem.${system}.dev.johnrinehart.slicemk-update;
        in
        {
          slicemk-update = {
            type = "app";
            program = "${package}/bin/slicemk-update";
            meta.description = package.meta.description;
          };
        }
      );
      aarch64DarwinPkgs = mkPkgs "aarch64-darwin" [
        (import ./packages/spice-quartz-overlay.nix)
      ];

      bootstrapIso = aarch64DarwinPkgs.fetchurl {
        url = "https://releases.nixos.org/nixos/unstable/nixos-26.11pre1124497.0bb8272318b4/nixos-minimal-26.11pre1124497.0bb8272318b4-aarch64-linux.iso";
        hash = "sha256-STj4w9MCAPFXhIzwDN4oxqK/09dvcIJRKw+3NW9tg4E=";
      };
      guestFlake = "path:${self.outPath}";
      installerBoot = aarch64DarwinPkgs.callPackage ./packages/nixos-installer-boot.nix {
        inherit bootstrapIso;
      };
      serialProvisioner = aarch64DarwinPkgs.callPackage ./packages/serial-provisioner.nix {
        inherit guestFlake;
      };
      vmArgs = {
        inherit
          bootstrapIso
          guestFlake
          installerBoot
          serialProvisioner
          ;
      };
      mbpAppleSiliconQemuVm = aarch64DarwinPkgs.callPackage ./packages/mbp-apple-silicon-qemu-vm.nix vmArgs;

      mbpHostModule = import ./darwin-configurations/mbp-host {
        inherit inputs;
      };
      mkMbpHost =
        {
          modules ? [ ],
        }:
        inputs.nix-darwin.lib.darwinSystem {
          modules = [ mbpHostModule ] ++ modules;
        };
      mkProvisionMacPackage =
        darwinConfiguration:
        aarch64DarwinPkgs.callPackage ./packages/provision-mac.nix {
          inherit darwinConfiguration;
        };
      mkProvisionMac = darwinConfiguration: {
        type = "app";
        program = "${mkProvisionMacPackage darwinConfiguration}/bin/provision-mac";
      };
      mbpHost = mkMbpHost { };
      configurationPackages = {
        mbp-apple-silicon-qemu-vm = mbpAppleSiliconQemuVm;
        provision-mac = mkProvisionMacPackage mbpHost;
      };

      # `nix run .#netboot -- NAME` serves nixosConfigurations.NAME (which
      # imports nixosModules.netboot) over PXE. `flake` is where NAME is
      # looked up by default, so a downstream flake passes its own `self`.
      mkNetbootPackages =
        flake:
        lib.genAttrs systems (system: {
          netboot = pkgsBySystem.${system}.callPackage ./packages/netboot/package.nix {
            inherit flake;
          };
        });
      netbootPackages = mkNetbootPackages self;
      mkNetbootApps =
        flake:
        lib.mapAttrs (_: packages: {
          netboot = {
            type = "app";
            program = lib.getExe packages.netboot;
            meta.description = packages.netboot.meta.description;
          };
        }) (mkNetbootPackages flake);
    in
    flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [ inputs.flake-parts.flakeModules.partitions ];

      inherit systems;

      partitionedAttrs = {
        checks = "dev";
        devShells = "dev";
        formatter = "dev";
      };

      partitions.dev = {
        extraInputsFlake = ./dev;
        module =
          { inputs, ... }:
          {
            perSystem =
              { system, ... }:
              let
                pkgs = pkgsBySystem.${system};
                treefmtEval = inputs.treefmt-nix.lib.evalModule pkgs ./treefmt.nix;
                preCommitCheck = inputs.git-hooks.lib.${system}.run {
                  src = ./.;
                  hooks.treefmt-nix = {
                    enable = true;
                    name = "treefmt";
                    entry = "${treefmtEval.config.build.wrapper}/bin/treefmt --fail-on-change";
                    language = "system";
                    pass_filenames = false;
                  };
                };
                functionalChecks = import ./nix/checks {
                  inputs = moduleInputs;
                  inherit pkgs;
                };
              in
              {
                devShells = import ./dev-shells.nix {
                  inherit pkgs preCommitCheck;
                  treefmtBin = treefmtEval.config.build.wrapper;
                };

                checks = functionalChecks // {
                  pre-commit = preCommitCheck;
                  formatting = treefmtEval.config.build.check self;
                };

                formatter = treefmtEval.config.build.wrapper;
              };
          };
      };

      flake = {
        inherit overlays;
        lib = unifiedLib // {
          inherit
            mkMbpHost
            mkNetbootApps
            mkNetbootPackages
            mkProvisionMac
            mkProvisionMacPackage
            ;
        };

        nixosModules = reusableNixosModules // {
          mbp-intel-silicon = {
            imports = [
              reusableNixosModules.default
              ./nixos-configurations/mbp-intel-silicon
            ];
            nixpkgs.overlays = [ overlays.default ];
          };

          mbp-apple-silicon =
            { lib, ... }:
            {
              imports = [
                reusableNixosModules.default
                ./nixos-configurations/mbp-apple-silicon
              ];
              nixpkgs.overlays = [ overlays.default ];
              _module.args.inputs = lib.mkDefault inputs;
            };
        };

        nixosConfigurations = (import ./nixos-configurations inputs) // {
          nebula-lighthouse = unifiedLib.nixosSystem {
            modules = [ ./nixos-configurations/nebula-lighthouse ];
            specialArgs = { inherit inputs; };
          };
          mbp-apple-silicon-bootstrap = unifiedLib.nixosSystem {
            modules = [ ./nixos-configurations/mbp-apple-silicon/bootstrap.nix ];
            specialArgs = { inherit inputs; };
          };
        };

        mixosModules = {
          cloudflare-ddns = ./mixos-modules/cloudflare-ddns.nix;
          mycelium = ./mixos-modules/mycelium.nix;
          sops = ./mixos-modules/sops.nix;
        };
        mixosConfigurations = import ./mixos-configurations inputs;

        darwinModules = {
          keyboard-remap = ./darwin-modules/keyboard-remap;
          mbp-host = mbpHostModule;
        };
        darwinConfigurations.mbp-host = mbpHost;

        legacyPackages = pkgsBySystem;
        packages = lib.mapAttrs (system: packages: packages // netbootPackages.${system}) (
          reusablePackages
          // {
            aarch64-darwin = reusablePackages.aarch64-darwin // configurationPackages;
          }
        );
        apps =
          lib.mapAttrs
            (
              system: apps:
              apps
              // (mkNetbootApps self).${system}
              // lib.optionalAttrs (inputs.nixos-uz801.apps ? ${system}) {
                uz801-deploy =
                  let
                    pkgs = pkgsBySystem.${system};
                    upstreamDeploy = inputs.nixos-uz801.apps.${system}.deploy.program;
                    manifest = self.mixosConfigurations.uz801-0.config.sops.deployManifest;
                    nebulaPkg = pkgs.callPackage ./packages/nebula.nix { };
                    wrapper = pkgs.writeShellApplication {
                      name = "uz801-deploy";
                      runtimeInputs = [
                        pkgs.jq
                        pkgs.openssh
                        pkgs.sops
                        pkgs.ssh-to-age
                        nebulaPkg
                      ];
                      text = ''
                        host=""
                        skip_secrets=0
                        has_image_or_flake=0
                        pass_args=()
                        while [ "$#" -gt 0 ]; do
                          case "$1" in
                            --host)
                              host="$2"
                              pass_args+=("$1" "$2")
                              shift 2
                              ;;
                            --skip-secrets)
                              skip_secrets=1
                              shift
                              ;;
                            --image|--flake)
                              has_image_or_flake=1
                              pass_args+=("$1" "$2")
                              shift 2
                              ;;
                            *)
                              pass_args+=("$1")
                              shift
                              ;;
                          esac
                        done

                        if [ "$skip_secrets" -eq 0 ] && [ -n "$host" ]; then
                          if [ -z "''${SOPS_AGE_KEY_FILE:-}" ] && [ -z "''${SOPS_AGE_KEY_CMD:-}" ] && [ -z "''${SOPS_AGE_KEY:-}" ]; then
                            if [ -r /etc/ssh/ssh_host_ed25519_key ]; then
                              export SOPS_AGE_KEY_CMD="${lib.getExe pkgs.ssh-to-age} -private-key -i /etc/ssh/ssh_host_ed25519_key"
                            fi
                          fi
                          ssh_opts=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)
                          echo "==> Decrypting and installing SOPS secrets to $host:/state/secrets..."
                          ssh -n "''${ssh_opts[@]}" "$host" 'mkdir -p /state/secrets && chmod 0700 /state/secrets'
                          while IFS= read -r entry; do
                            name=$(printf '%s\n' "$entry" | jq -r '.name')
                            sops_file=$(printf '%s\n' "$entry" | jq -r '.sopsFile')
                            key=$(printf '%s\n' "$entry" | jq -r '.key')
                            dest=$(printf '%s\n' "$entry" | jq -r '.path')
                            mode=$(printf '%s\n' "$entry" | jq -r '.mode')
                            optional=$(printf '%s\n' "$entry" | jq -r '.optional')
                            tmp=$(mktemp)
                            if sops -d --extract "[\"$key\"]" "$sops_file" > "$tmp" 2>/dev/null; then
                              if [ "$name" = "nebula-lighthouse-cert" ]; then
                                if nebula-cert print -json -path "$tmp" | grep -Eq '"groups":\[[^]]*"peer"'; then
                                  rm -f "$tmp"
                                  echo "uz801-deploy: refusing to deploy lighthouse cert with 'peer' group" >&2
                                  exit 1
                                fi
                              fi
                              dest_dir=$(dirname "$dest")
                              # shellcheck disable=SC2029
                              ssh "''${ssh_opts[@]}" "$host" "mkdir -p '$dest_dir' && cat > '$dest.tmp' && chmod '$mode' '$dest.tmp' && mv -f '$dest.tmp' '$dest'" < "$tmp"
                              rm -f "$tmp"
                            else
                              rm -f "$tmp"
                              if [ "$optional" = "true" ]; then
                                echo "    skipping optional secret: $name" >&2
                              else
                                echo "uz801-deploy: failed to decrypt required secret '$key' from $sops_file" >&2
                                exit 1
                              fi
                            fi
                          done < <(jq -c '.[]' ${manifest})
                        fi

                        if [ "$has_image_or_flake" -eq 0 ]; then
                          pass_args+=(--flake ".#mixosConfigurations.uz801-0.config.system.build.slotImage")
                        fi
                        exec ${upstreamDeploy} "''${pass_args[@]}"
                      '';
                    };
                  in
                  {
                    type = "app";
                    program = lib.getExe wrapper;
                    meta.description = "Decrypt SOPS secrets on host and deploy uz801-0 A/B slot image";
                  };
              }
            )
            (
              slicemkApps
              // {
                aarch64-darwin = slicemkApps.aarch64-darwin // {
                  mbp-apple-silicon-qemu-vm = {
                    type = "app";
                    program = "${mbpAppleSiliconQemuVm}/bin/mbp-apple-silicon-qemu-vm";
                  };
                  provision-mac = mkProvisionMac mbpHost;
                };
              }
            );
      };
    };
}
