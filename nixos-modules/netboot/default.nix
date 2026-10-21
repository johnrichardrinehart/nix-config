# Netboot a whole desktop: the system runs from RAM with nothing on disk.
#
# nixpkgs' netboot module puts the closure in one squashfs inside the initrd.
# An initrd is a newc cpio archive, whose file size field is eight hex digits,
# so no file in it can reach 4 GiB; a desktop closure compresses to more than
# that. This module splits the store into a fixed number of squashfs parts,
# each below that limit, mounts every part under /nix/.ro-store and joins them
# as the overlay's lower layers.
#
# The part count is fixed at evaluation time because it shapes the boot-time
# mounts; the build packs the closure into that many parts and fails, naming
# the count it needs, when they do not fit.
{
  config,
  lib,
  modulesPath,
  pkgs,
  ...
}:
let
  cfg = config.dev.johnrinehart.netboot;
  partIndices = lib.range 0 (cfg.storeParts - 1);
  partName = i: "nix-store-part-${toString i}.squashfs";
  partMountPoint = i: "/nix/.ro-store/part-${toString i}";

  closureInfo = pkgs.closureInfo { rootPaths = config.netboot.storeContents; };

  squashfsParts =
    pkgs.runCommand "nix-store-squashfs-parts"
      {
        nativeBuildInputs = [
          pkgs.python3
          pkgs.squashfsTools
        ];
        # The parts are self-contained copies of the closure.
        __structuredAttrs = true;
        unsafeDiscardReferences.out = true;
      }
      ''
        mkdir -p "$out" bins
        python3 ${./split-store.py} \
          --parts ${toString cfg.storeParts} \
          --max-bytes ${toString cfg.maxPartBytes} \
          --out-dir bins \
          < ${closureInfo}/store-paths

        # nix-store --load-db input for the whole closure, read by
        # register-nix-paths from /nix/store/nix-path-registration; part 0 only.
        cp ${closureInfo}/registration nix-path-registration
        mkdir empty

        for i in ${lib.concatMapStringsSep " " toString partIndices}; do
          sources=()
          if [ "$i" = 0 ]; then
            sources+=(nix-path-registration)
          fi
          mapfile -t -O "''${#sources[@]}" sources < "bins/$i"
          if [ "''${#sources[@]}" = 0 ]; then
            sources=(empty)
            keep=()
          else
            keep=(-keep-as-directory)
          fi

          # Same flags as nixpkgs' make-squashfs.nix, which netboot.nix uses.
          SOURCE_DATE_EPOCH=0 mksquashfs "''${sources[@]}" "$out/nix-store-part-$i.squashfs" \
            -no-hardlinks "''${keep[@]}" -all-root -b 1048576 \
            -comp ${config.netboot.squashfsCompression} \
            -processors "$NIX_BUILD_CORES" -root-mode 0755 -quiet -no-progress

          size=$(stat -c %s "$out/nix-store-part-$i.squashfs")
          if [ "$size" -ge ${toString cpioFileLimit} ]; then
            echo "nix-store-part-$i.squashfs is $size bytes, too large for a cpio archive;" \
              "lower dev.johnrinehart.netboot.maxPartBytes and raise storeParts" >&2
            exit 1
          fi
        done
      '';

  # Largest file a newc cpio header can describe.
  cpioFileLimit = 4294967295;

  installTarget = cfg.installer.target.config;
  installDisks = map (disk: disk.device) (lib.attrValues installTarget.disko.devices.disk);
  installRoot = installTarget.disko.rootMountPoint;
  installToDisk = pkgs.writeShellApplication {
    name = "install-to-disk";
    runtimeInputs = [
      config.system.build.nixos-install
      pkgs.util-linux
    ];
    text = ''
      usage() {
        cat <<EOF
      Usage: install-to-disk [--yes]

      Installs ${installTarget.networking.hostName} onto ${toString installDisks},
      erasing ${if lib.length installDisks == 1 then "it" else "them"}:
        1. partitions and formats with disko, which asks for the LUKS
           passphrase twice on standard input,
        2. installs ${installTarget.system.build.toplevel}
           at ${installRoot} with nixos-install, from this system's store.

        --yes   do not ask before erasing
      EOF
      }

      wipe=()
      case "''${1:-}" in
      "") ;;
      --yes) wipe=(--yes-wipe-all-disks) ;;
      -h | --help)
        usage
        exit 0
        ;;
      *)
        usage >&2
        exit 64
        ;;
      esac

      if [ "$(id -u)" != 0 ]; then
        echo "install-to-disk: run as root (sudo install-to-disk)" >&2
        exit 1
      fi

      lsblk -o NAME,SIZE,MODEL,FSTYPE,MOUNTPOINTS ${lib.escapeShellArgs installDisks}

      ${installTarget.system.build.destroyFormatMount}/bin/disko-destroy-format-mount "''${wipe[@]}"

      nixos-install --root ${lib.escapeShellArg installRoot} \
        --system ${installTarget.system.build.toplevel} \
        --no-root-passwd --no-channel-copy

      umount -R ${lib.escapeShellArg installRoot}
      echo "Installed ${installTarget.networking.hostName}. Reboot and boot from the disk."
    '';
  };
in
{
  imports = [ "${modulesPath}/installer/netboot/netboot.nix" ];

  options.dev.johnrinehart.netboot = {
    storeParts = lib.mkOption {
      type = lib.types.ints.positive;
      default = 8;
      description = ''
        Number of squashfs images the Nix store is split into. Unused parts
        are empty images. Raise it when the build says the closure does not
        fit.
      '';
    };

    maxPartBytes = lib.mkOption {
      type = lib.types.ints.positive;
      # 3.75 GiB of file contents stays below the 4 GiB cpio limit even when
      # nothing compresses; the build checks each image anyway.
      default = 4026531840;
      description = ''
        Upper bound on the apparent size of the store paths packed into one
        squashfs part, before compression.
      '';
    };

    installer.target = lib.mkOption {
      type = lib.types.nullOr lib.types.raw;
      default = null;
      example = lib.literalExpression "inputs.self.nixosConfigurations.my-laptop";
      description = ''
        A NixOS configuration, as `nixosSystem` returns it, that imports
        disko's module and describes its disks in `disko.devices`. When set,
        the netbooted system carries that configuration's closure and an
        `install-to-disk` command, run as root, which partitions and formats
        those disks with disko (destroying what is on them) and installs the
        configuration onto them with nixos-install, without the network.
      '';
    };
  };

  config = {
    netboot.storeContents = lib.mkIf (cfg.installer.target != null) [
      installTarget.system.build.toplevel
      installTarget.system.build.destroyFormatMount
    ];
    environment.systemPackages = lib.mkIf (cfg.installer.target != null) [ installToDisk ];

    fileSystems = {
      # A tmpfs to hold the part mount points.
      "/nix/.ro-store" = lib.mkForce {
        fsType = "tmpfs";
        options = [
          "mode=0755"
          "size=1M"
        ];
        neededForBoot = true;
      };

      # netboot.nix defines this whole entry with mkImageMediaOverride, which
      # would win over a plain definition of lowerdir alone.
      "/nix/store" = lib.mkForce {
        overlay = {
          lowerdir = map partMountPoint partIndices;
          upperdir = "/nix/.rw-store/store";
          workdir = "/nix/.rw-store/work";
        };
        neededForBoot = true;
      };
    }
    // lib.listToAttrs (
      map (
        i:
        lib.nameValuePair (partMountPoint i) {
          fsType = "squashfs";
          device = "../${partName i}";
          options = [
            "loop"
          ]
          ++ lib.optional (config.boot.kernelPackages.kernel.kernelAtLeast "6.2") "threads=multi";
          neededForBoot = true;
        }
      ) partIndices
    );

    system.build.squashfsStoreParts = squashfsParts;

    # nixpkgs' script, plus ifclose before boot. snponly.efi drives the NIC
    # through the firmware's driver; left open, the Framework 13 (Ryzen AI
    # 300) firmware's USB UNDI hangs the kernel's EFI stub right after it
    # measures the initrd ("into PCR 9"), with any kernel.
    system.build.netbootIpxeScript = lib.mkForce (
      pkgs.writeTextDir "netboot.ipxe" ''
        #!ipxe
        # Use the cmdline variable to allow the user to specify custom kernel params
        # when chainloading this script from other iPXE scripts like netboot.xyz
        kernel ${pkgs.stdenv.hostPlatform.linux-kernel.target} init=${config.system.build.toplevel}/init initrd=initrd ${toString config.boot.kernelParams} ''${cmdline}
        initrd initrd
        ifclose
        boot
      ''
    );

    # What a PXE server hands out over HTTP; netboot.ipxe names the other two
    # relative to its own URL.
    system.build.netbootTree = pkgs.symlinkJoin {
      name = "netboot-tree";
      paths = [
        config.system.build.kernel
        config.system.build.netbootRamdisk
        config.system.build.netbootIpxeScript
      ];
    };

    # iPXE for the firmware to load over TFTP. snponly.efi drives the NIC
    # through the firmware's own network stack, so it works with any card the
    # firmware can PXE boot from, USB expansion cards included. It fetches the
    # server's boot.ipxe from the TFTP server that served it.
    system.build.netbootIpxeEfi =
      let
        ipxe = pkgs.ipxe.override {
          enableDefaultPlatformTargets = false;
          additionalTargets."bin-x86_64-efi/snponly.efi" = null;
          firmwareBinary = "snponly.efi";
          embedScript = pkgs.writeText "chain-boot.ipxe" ''
            #!ipxe
            dhcp || goto failed
            isset ''${proxydhcp/next-server} && set server ''${proxydhcp/next-server} || set server ''${next-server}
            chain tftp://''${server}/boot.ipxe || goto failed
            :failed
            echo Netboot failed; dropping to the iPXE shell.
            shell
          '';
        };
      in
      "${ipxe}/snponly.efi";

    # The stage 1 initrd, then an uncompressed cpio archive of the parts: the
    # parts are already compressed, and the kernel unpacks concatenated
    # archives in order. An uncompressed archive must start on a 4-byte
    # boundary; the kernel skips the zero padding before it.
    system.build.netbootRamdisk = lib.mkForce (
      pkgs.runCommand "netboot-initrd"
        {
          nativeBuildInputs = [ pkgs.cpio ];
          __structuredAttrs = true;
          unsafeDiscardReferences.out = true;
        }
        ''
          mkdir "$out"
          cat ${config.system.build.initialRamdisk}/${config.system.boot.loader.initrdFile} > "$out/initrd"
          size=$(stat -c %s "$out/initrd")
          head -c $(( (512 - size % 512) % 512 )) /dev/zero >> "$out/initrd"
          (
            cd ${squashfsParts}
            ls -1 nix-store-part-*.squashfs \
              | cpio --quiet -o -H newc --reproducible -R +0:+0
          ) >> "$out/initrd"
        ''
    );
  };
}
