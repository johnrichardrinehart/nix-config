{
  description = "Unified JohnOS Nix configuration, modules, overlays, and packages";

  inputs = {
    flake-parts.url = "github:hercules-ci/flake-parts";

    nixpkgs.url = "github:NixOS/nixpkgs?ref=nixos-26.05";

    # Newer nixos-26.05 for framework-13-pro's kernel only (Linux 7.3; see
    # nixos-configurations/framework-13-pro/hardware.nix).
    nixpkgs-kernel.url = "github:NixOS/nixpkgs?ref=nixos-26.05";

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

    home-manager = {
      # release-26.05 plus nix-community/home-manager#10006.
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

    monstar = {
      url = "github:rockorager/monstar";
      inputs.nixpkgs.follows = "nixpkgs";
    };

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
        builtins.elem (lib.getName pkg) [
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
        url = "https://releases.nixos.org/nixos/unstable/nixos-26.11pre1082427.b4fd65b198c5/nixos-minimal-26.11pre1082427.b4fd65b198c5-aarch64-linux.iso";
        hash = "sha256-muUaIkjXmRRsz8xzHSeBEXd0+6xto1HMZT+xqh4RvVU=";
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

        darwinModules.mbp-host = mbpHostModule;
        darwinConfigurations.mbp-host = mbpHost;

        legacyPackages = pkgsBySystem;
        packages = lib.mapAttrs (system: packages: packages // netbootPackages.${system}) (
          reusablePackages
          // {
            aarch64-darwin = reusablePackages.aarch64-darwin // configurationPackages;
          }
        );
        apps = lib.mapAttrs (system: apps: apps // (mkNetbootApps self).${system}) (
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
