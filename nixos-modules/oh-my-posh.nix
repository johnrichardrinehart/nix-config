{ lib, ... }:
{
  options.dev.johnrinehart.programs.oh-my-posh.git.ignoreStatus = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [ ];
    example = [ "/home/john/code/.*" ];
    description = ''
      Repositories whose working-tree status the prompt's git segment does not
      fetch. Each entry is a regular expression that must match the repository
      root directory in full (oh-my-posh's `ignore_status`, matched like its
      `exclude_folders`); a leading `~` stands for the home directory.

      The segment normally runs `git status --porcelain=2 --branch` on every
      prompt, which stats every index entry. On a filesystem where each lookup
      is a round trip - a 9p share into a guest, a network mount - that is
      seconds per prompt for a repository of a few thousand files. Matching
      repositories keep the branch name and lose the dirty and ahead/behind
      indicators.
    '';
  };
}
