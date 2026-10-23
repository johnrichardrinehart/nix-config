# The NVMe drive: a 10 GiB ESP for /boot (1 GiB fills up with kernels and
# initrds), and the rest LUKS2 with ext4 for /.
#
# ext4 for the workload this disk sees most: model files read sequentially,
# and the many small random reads and writes of `nix eval`, `git fetch` and
# the Nix store. noatime drops the metadata write per read; fast_commit makes
# the fsyncs Git and Nix issue cheap; TRIM goes through in fstrim's weekly
# batches (nixos-hardware's SSD profile) rather than on every delete.
# allowDiscards lets those batches reach the drive through LUKS, and
# bypassWorkqueues skips dm-crypt's queues, which only add latency on NVMe.
{
  disko.devices.disk.nvme0n1 = {
    type = "disk";
    device = "/dev/nvme0n1";
    content = {
      type = "gpt";
      partitions = {
        ESP = {
          type = "EF00";
          size = "10G";
          content = {
            type = "filesystem";
            format = "vfat";
            mountpoint = "/boot";
            # Private from the first mount, which nixos-install does through
            # disko; bootctl refuses a world-readable random seed.
            mountOptions = [ "umask=0077" ];
            extraArgs = [
              "-n"
              "ESP"
            ];
          };
        };
        root = {
          size = "100%";
          content = {
            type = "luks";
            name = "cryptroot";
            # disko asks for the passphrase twice, on standard input, when it
            # formats the partition.
            askPassword = true;
            # The endpoint security baseline asks for LUKS2 by name.
            extraFormatArgs = [
              "--type"
              "luks2"
            ];
            settings = {
              allowDiscards = true;
              bypassWorkqueues = true;
            };
            content = {
              type = "filesystem";
              format = "ext4";
              mountpoint = "/";
              mountOptions = [ "noatime" ];
              # ext4 reserves 5% for root by default: 186 GiB on this 4 TB
              # drive. 1% (37 GiB) is plenty for one user's machine.
              extraArgs = [
                "-L"
                "nixos"
                "-O"
                "fast_commit"
                "-m"
                "1"
              ];
            };
          };
        };
      };
    };
  };
}
