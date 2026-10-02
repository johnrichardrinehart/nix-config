{
  description = "Reusable JohnOS NixOS modules, overlays, and packages";

  inputs = {
    nixpkgs.url = "github:johnrichardrinehart/nixpkgs?ref=rock-5c-nixos-26.05";

    flake-parts.url = "github:hercules-ci/flake-parts";

    display-layout = {
      url = "github:johnrichardrinehart/display-layout";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    git-meld = {
      url = "github:johnrichardrinehart/git-meld";
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

    repo-manager = {
      url = "github:johnrichardrinehart/repo-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    home-manager = {
      url = "github:nix-community/home-manager/release-26.05";
      flake = true;
      inputs.nixpkgs.follows = "nixpkgs";
    };

    sops-nix = {
      url = "github:mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{ flake-parts, ... }:
    let
      allowUnfreePackages =
        pkg:
        builtins.elem (inputs.nixpkgs.lib.getName pkg) [
          "context-mode"
          "moonshine-models-source"
        ];
    in
    flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [ inputs.flake-parts.flakeModules.partitions ];

      systems = [
        "aarch64-darwin"
        "aarch64-linux"
        "x86_64-linux"
      ];

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
                overlays = import ./overlays inputs;
                pkgs = import inputs.nixpkgs {
                  inherit system;
                  overlays = [ overlays.default ];
                  config.allowUnfreePredicate = allowUnfreePackages;
                };
                treefmtEval = inputs."treefmt-nix".lib.evalModule pkgs ./treefmt.nix;
                preCommitCheck = inputs."git-hooks".lib.${system}.run {
                  src = ./.;
                  hooks = {
                    treefmt-nix = {
                      enable = true;
                      name = "treefmt";
                      entry = "${treefmtEval.config.build.wrapper}/bin/treefmt --fail-on-change";
                      language = "system";
                      pass_filenames = false;
                    };
                  };
                };
              in
              {
                devShells = import ./dev-shells.nix {
                  inherit pkgs;
                  inherit preCommitCheck;
                  treefmtBin = treefmtEval.config.build.wrapper;
                };

                checks = {
                  pre-commit = preCommitCheck;
                  formatting = treefmtEval.config.build.check inputs.self;
                  agent-tools-module = import ./nix/checks/agent-tools-module.nix {
                    inherit inputs pkgs;
                    inherit (inputs.nixpkgs) lib;
                  };
                  auto-suspend-module = import ./nix/checks/auto-suspend-module.nix {
                    inherit inputs pkgs;
                    inherit (inputs.nixpkgs) lib;
                  };
                  brightness-sync = import ./nix/checks/brightness-sync.nix {
                    inherit pkgs;
                    inherit (inputs.nixpkgs) lib;
                  };
                  daylight-display-module = import ./nix/checks/daylight-display-module.nix {
                    inherit inputs pkgs;
                    inherit (inputs.nixpkgs) lib;
                  };
                  git-meld-module = import ./nix/checks/git-meld-module.nix {
                    inherit inputs pkgs;
                    inherit (inputs.nixpkgs) lib;
                  };
                  kitkat-rs-module = import ./nix/checks/kitkat-rs-module.nix {
                    inherit inputs pkgs;
                    inherit (inputs.nixpkgs) lib;
                  };
                  mycelium-module = import ./nix/checks/mycelium-module.nix {
                    inherit inputs pkgs;
                    inherit (inputs.nixpkgs) lib;
                  };
                  mycelium-tls = import ./nix/checks/mycelium-tls.nix {
                    inherit pkgs;
                  };
                  nebula-registry = import ./nix/checks/nebula-registry.nix {
                    inherit pkgs;
                    inherit (inputs.nixpkgs) lib;
                  };
                  ssh-session = import ./nix/checks/ssh-session.nix {
                    inherit pkgs;
                    inherit (inputs.nixpkgs) lib;
                  };
                };

                formatter = treefmtEval.config.build.wrapper;
              };
          };
      };

      flake = {
        lib = inputs.nixpkgs.lib // {
          daylightDisplay = import ./lib/daylight-display.nix;
        };

        nixosModules = {
          default = import ./nixos-modules {
            inherit inputs;
            inherit (inputs.nixpkgs) lib;
          };
          mycelium = ./nixos-modules/nebula/mycelium;
          nebula = ./nixos-modules/nebula;
        };

        overlays = import ./overlays inputs;
      };

      perSystem =
        { system, ... }:
        let
          overlays = import ./overlays inputs;
          pkgs = import inputs.nixpkgs {
            inherit system;
            overlays = [ overlays.default ];
            config.allowUnfreePredicate = allowUnfreePackages;
          };
        in
        {
          packages = import ./packages { inherit pkgs; };
          legacyPackages = pkgs;
        };
    };
}
