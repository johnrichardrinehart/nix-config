#!/usr/bin/env bash
set -euo pipefail

temporary_directory=""
temporary_refs=()

cleanup() {
  local ref
  for ref in "${temporary_refs[@]}"; do
    git update-ref -d "$ref" >/dev/null 2>&1 || true
  done
  if [[ -n $temporary_directory ]]; then
    rm -rf -- "$temporary_directory"
  fi
}
trap cleanup EXIT

usage() {
  cat <<'EOF'
Usage:
  git patch-wormhole send <base>:<branch>:<revision-range> [...]
  git patch-wormhole send [<revision-selection argument>...]
  git patch-wormhole receive <code> [--branch <name>] [--base <revision>]

Every archive contains exact Git commit objects and their synchronization
metadata. receive preserves commit hashes when the receiving HEAD is the
original base. A base:branch:revision-range argument describes one head;
any number of heads can be bundled together. Leave branch empty
(base::revision-range) to receive that head detached.

The second send form creates one unnamed head. --branch and --base apply
only to that form. A supplied --base must resolve to the original base;
applying the commits to a different base is intentionally unsupported.

Examples:
  git patch-wormhole send main:feature:main..feature
  git patch-wormhole send main:feature:main..feature release:fix:release..fix
  git patch-wormhole send main::main..experiment
  git patch-wormhole send main..feature
  git patch-wormhole receive 7-example-code
  git patch-wormhole receive 7-example-code --branch feature --base main

EOF
}

die() {
  printf 'git-patch-wormhole: %s\n' "$*" >&2
  exit 1
}

require_repository() {
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
    die "the current directory is not inside a Git worktree"
}

is_head_specification() {
  local remainder
  remainder="${1#*:}"
  [[ $remainder != "$1" && $remainder == *:* ]]
}
write_exact_head() {
  local bundle_directory="$1"
  local head_id="$2"
  local base="$3"
  local branch="$4"
  shift 4
  local oid parent_line expected_parent tip exact_ref revision_output
  local -a commit_oids parent_fields

  revision_output="$(git rev-list --reverse "$@")" ||
    die "invalid revision selection for head $head_id: $*"
  [[ -n $revision_output ]] ||
    die "the revision selection for head $head_id produced no commits: $*"
  mapfile -t commit_oids <<<"$revision_output"

  for oid in "${commit_oids[@]}"; do
    git cat-file -e "$oid^{commit}" ||
      die "selected commit is not available: $oid"
  done

  if [[ -z $base ]]; then
    parent_line="$(git rev-list --parents --max-count=1 "${commit_oids[0]}")"
    read -r -a parent_fields <<<"$parent_line"
    ((${#parent_fields[@]} == 2)) ||
      die "root and merge commits cannot be sent as an exact commit series"
    base="${parent_fields[1]}"
  fi

  expected_parent="$base"
  for oid in "${commit_oids[@]}"; do
    parent_line="$(git rev-list --parents --max-count=1 "$oid")"
    read -r -a parent_fields <<<"$parent_line"
    ((${#parent_fields[@]} == 2)) ||
      die "commit $oid is not part of a linear, non-merge commit series"
    [[ ${parent_fields[1]} == "$expected_parent" ]] ||
      die "commit $oid does not follow the stored base and preceding commits"
    expected_parent="$oid"
  done
  tip="${commit_oids[-1]}"

  exact_ref="refs/git-patch-wormhole/${PPID}-${RANDOM}-$head_id"
  git update-ref "$exact_ref" "$tip"
  temporary_refs+=("$exact_ref")
  git bundle create "$bundle_directory/head-$head_id.bundle" "$exact_ref" "^$base"
  git update-ref -d "$exact_ref"

  printf '%s\n' "$base" >"$bundle_directory/head-$head_id-base"
  printf '%s' "$branch" >"$bundle_directory/head-$head_id-branch"
  printf '%s\n' "$tip" >"$bundle_directory/head-$head_id-tip"
  printf '%s\n' "$exact_ref" >"$bundle_directory/head-$head_id-ref"
  printf '%d\n' "${#commit_oids[@]}" >"$bundle_directory/head-$head_id-count"
  ((commit_count += ${#commit_oids[@]}))
}

send_single_head_bundle() {
  local bundle_directory archive manifest
  local commit_count=0

  bundle_directory="$temporary_directory/bundle"
  archive="$temporary_directory/git-commits.zip"
  manifest="$bundle_directory/manifest"
  mkdir -p -- "$bundle_directory"
  printf 'git-patch-wormhole-exact\nsingle\n0001\n' >"$manifest"

  write_exact_head "$bundle_directory" "0001" "" "" "$@"

  (
    cd "$bundle_directory"
    zip -q "$archive" -- ./*
  )

  printf 'Sending 1 head containing %d commit(s). The recipient code follows.\n' \
    "$commit_count"
  wormhole-rs --no-color send --no-qr --rename git-commits.zip "$archive"
}

send_multi_head_bundle() {
  local bundle_directory archive manifest
  local specification remainder base branch revision_range
  local head_id
  local head_count=0
  local commit_count=0

  bundle_directory="$temporary_directory/bundle"
  archive="$temporary_directory/git-commits.zip"
  manifest="$bundle_directory/manifest"
  mkdir -p -- "$bundle_directory"
  printf 'git-patch-wormhole-exact\nmulti\n' >"$manifest"

  for specification in "$@"; do
    remainder="${specification#*:}"
    base="${specification%%:*}"
    branch="${remainder%%:*}"
    revision_range="${remainder#*:}"

    [[ -n $base ]] || die "a head specification has an empty base: $specification"
    [[ -n $revision_range ]] ||
      die "a head specification has an empty revision range: $specification"
    if [[ -n $branch ]]; then
      git check-ref-format --branch "$branch" >/dev/null 2>&1 ||
        die "invalid branch name in head specification: $branch"
    fi
    base="$(git rev-parse --verify "$base^{commit}")" ||
      die "base does not resolve to a commit: $base"

    ((head_count += 1))
    printf -v head_id '%04d' "$head_count"
    printf '%s\n' "$head_id" >>"$manifest"
    write_exact_head "$bundle_directory" "$head_id" "$base" "$branch" "$revision_range"
  done

  (
    cd "$bundle_directory"
    zip -q "$archive" -- ./*
  )

  printf 'Sending %d head(s) containing %d commit(s). The recipient code follows.\n' \
    "$head_count" "$commit_count"
  wormhole-rs --no-color send --no-qr --rename git-commits.zip "$archive"
}

send_bundle() {
  local argument
  local any_head_specification=false
  local all_head_specifications=true

  (($# > 0)) || die "send requires a head specification or Git revision selection"
  require_repository

  for argument in "$@"; do
    if is_head_specification "$argument"; then
      any_head_specification=true
    else
      all_head_specifications=false
    fi
  done
  if "$any_head_specification" && ! "$all_head_specifications"; then
    die "cannot mix base:branch:revision-range arguments with single-head revision arguments"
  fi

  temporary_directory="$(mktemp -d -t git-patch-wormhole.XXXXXX)"
  if "$all_head_specifications"; then
    send_multi_head_bundle "$@"
  else
    send_single_head_bundle "$@"
  fi
}

validate_branch() {
  local branch="$1"
  local existing

  [[ -n $branch ]] || return 0
  git check-ref-format --branch "$branch" >/dev/null 2>&1 ||
    die "invalid branch name in archive: $branch"
  if git show-ref --verify --quiet "refs/heads/$branch"; then
    die "branch already exists: $branch"
  fi
  for existing in "${validated_branches[@]}"; do
    [[ $existing != "$branch" ]] || die "duplicate branch name in archive: $branch"
  done
  validated_branches+=("$branch")
}

receive_exact_bundle() {
  local bundle_directory="$1"
  local entry_count="$2"
  local requested_branch="$3"
  local requested_base="$4"
  local expected_id id mode base branch tip exact_ref count resolved_base expected_entry_count=1
  local index result start_spec current fetched bundle metadata
  local -a manifest_lines head_ids head_bases head_branches head_tips head_refs head_counts
  validated_branches=()

  mapfile -t manifest_lines <"$bundle_directory/manifest"
  ((${#manifest_lines[@]} > 2)) || die "the archive contains no heads"
  [[ ${manifest_lines[0]} == "git-patch-wormhole-exact" ]] ||
    die "the archive has an invalid manifest signature"
  mode="${manifest_lines[1]}"
  [[ $mode == "single" || $mode == "multi" ]] ||
    die "the archive has an invalid mode: $mode"
  if [[ $mode == "single" ]]; then
    ((${#manifest_lines[@]} == 3)) ||
      die "a single-head archive must contain exactly one head"
  elif [[ -n $requested_branch || -n $requested_base ]]; then
    die "--branch and --base cannot override a multi-head archive"
  fi

  for ((index = 2; index < ${#manifest_lines[@]}; index++)); do
    id="${manifest_lines[$index]}"
    printf -v expected_id '%04d' "$((index - 1))"
    [[ $id == "$expected_id" ]] ||
      die "the archive manifest contains an invalid head identifier: $id"
    for metadata in base branch tip ref count; do
      [[ -f "$bundle_directory/head-$id-$metadata" ]] ||
        die "head $id has no $metadata metadata"
    done
    [[ -f "$bundle_directory/head-$id.bundle" ]] ||
      die "head $id has no Git bundle"

    base="$(<"$bundle_directory/head-$id-base")"
    branch="$(<"$bundle_directory/head-$id-branch")"
    tip="$(<"$bundle_directory/head-$id-tip")"
    exact_ref="$(<"$bundle_directory/head-$id-ref")"
    count="$(<"$bundle_directory/head-$id-count")"
    bundle="$bundle_directory/head-$id.bundle"
    [[ $base =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]] ||
      die "head $id has an invalid base commit"
    [[ $tip =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]] ||
      die "head $id has an invalid tip commit"
    git check-ref-format "$exact_ref" >/dev/null 2>&1 ||
      die "head $id has an invalid bundle reference"
    resolved_base="$(git rev-parse --verify "$base^{commit}")" ||
      die "base commit for head $id is not available: $base"
    [[ $resolved_base == "$base" ]] ||
      die "base for head $id does not resolve to its stored commit: $base"
    git bundle verify "$bundle" >/dev/null 2>&1 ||
      die "head $id contains an invalid or incomplete Git bundle"
    if [[ $mode == "multi" ]]; then
      validate_branch "$branch"
    fi
    [[ $count =~ ^[1-9][0-9]*$ ]] ||
      die "head $id has an invalid commit count"
    ((expected_entry_count += 6))
    head_ids+=("$id")
    head_bases+=("$base")
    head_branches+=("$branch")
    head_tips+=("$tip")
    head_refs+=("$exact_ref")
    head_counts+=("$count")
  done

  ((expected_entry_count == entry_count)) ||
    die "the archive contains unreferenced or duplicate entries"

  if [[ $mode == "single" && -n $requested_base ]]; then
    resolved_base="$(git rev-parse --verify "$requested_base^{commit}")"
    [[ $resolved_base == "${head_bases[0]}" ]] ||
      die "--base resolves to $resolved_base, but exact synchronization requires ${head_bases[0]}"
  fi

  for index in "${!head_ids[@]}"; do
    id="${head_ids[$index]}"
    base="${head_bases[$index]}"
    branch="${head_branches[$index]}"
    tip="${head_tips[$index]}"
    exact_ref="${head_refs[$index]}"
    count="${head_counts[$index]}"
    bundle="$bundle_directory/head-$id.bundle"

    if [[ $mode == "single" ]]; then
      branch="$requested_branch"
      start_spec="${requested_base:-$base}"
      if [[ -n $branch ]]; then
        git switch -c "$branch" "$start_spec"
      elif [[ -n $requested_base ]]; then
        git checkout "$requested_base"
      fi
    elif [[ -n $branch ]]; then
      git switch -c "$branch" "$base"
    else
      git checkout --detach "$base"
    fi

    current="$(git rev-parse HEAD)"
    [[ $current == "$base" ]] ||
      die "head $id requires base $base, but HEAD is $current; check out the original base or use a matching --base"
    git fetch --quiet --no-tags "$bundle" "$exact_ref"
    fetched="$(git rev-parse "FETCH_HEAD^{commit}")"
    [[ $fetched == "$tip" ]] ||
      die "head $id bundle resolved to $fetched instead of $tip"

    printf 'Restoring %d commit(s) for head %s with exact hashes.\n' \
      "$count" "$id"
    if git symbolic-ref --quiet HEAD >/dev/null; then
      git merge --ff-only "$tip"
    else
      git checkout --detach "$tip"
    fi
    result="$(git rev-parse HEAD)"
    if [[ -n $branch ]]; then
      printf 'Created branch %s at %s.\n' "$branch" "$result"
    elif git symbolic-ref --quiet HEAD >/dev/null; then
      printf 'Advanced the current branch to %s.\n' "$result"
    else
      printf 'Created detached head %s. Create a branch to retain it.\n' "$result"
    fi
  done
}

receive_bundle() {
  local code="" branch="" base=""
  local download_directory bundle_directory archive entry
  local -a downloads entries extracted_entries

  while (($# > 0)); do
    case "$1" in
    --branch)
      (($# >= 2)) || die "--branch requires a name"
      branch="$2"
      shift 2
      ;;
    --branch=*)
      branch="${1#*=}"
      shift
      ;;
    --base)
      (($# >= 2)) || die "--base requires a revision"
      base="$2"
      shift 2
      ;;
    --base=*)
      base="${1#*=}"
      shift
      ;;
    --help | -h)
      usage
      exit 0
      ;;
    --)
      shift
      (($# == 1)) || die "receive accepts exactly one wormhole code"
      code="$1"
      shift
      ;;
    -*)
      die "unknown receive option: $1"
      ;;
    *)
      [[ -z $code ]] || die "receive accepts exactly one wormhole code"
      code="$1"
      shift
      ;;
    esac
  done

  [[ -n $code ]] || die "receive requires a wormhole code"
  require_repository

  if [[ -n $branch ]]; then
    git check-ref-format --branch "$branch" >/dev/null 2>&1 ||
      die "invalid branch name: $branch"
    if git show-ref --verify --quiet "refs/heads/$branch"; then
      die "branch already exists: $branch"
    fi
  fi

  if [[ -n $base ]]; then
    git rev-parse --verify --quiet "$base^{commit}" >/dev/null ||
      die "base does not resolve to a commit: $base"
  fi

  [[ -z "$(git status --porcelain --untracked-files=normal)" ]] ||
    die "the worktree must be clean before receiving commits"

  temporary_directory="$(mktemp -d -t git-patch-wormhole.XXXXXX)"
  download_directory="$temporary_directory/download"
  bundle_directory="$temporary_directory/bundle"
  mkdir -p -- "$download_directory" "$bundle_directory"

  wormhole-rs --no-color receive --noconfirm --out-dir "$download_directory" "$code"

  downloads=("$download_directory"/*)
  if ((${#downloads[@]} != 1)) || [[ ! -f ${downloads[0]} ]]; then
    die "the transfer did not contain exactly one archive"
  fi
  archive="${downloads[0]}"

  unzip -tq "$archive" >/dev/null || die "the received file is not a valid zip archive"
  mapfile -t entries < <(unzip -Z1 "$archive")
  ((${#entries[@]} > 0)) || die "the received archive is empty"
  for entry in "${entries[@]}"; do
    [[ -n $entry && $entry != */* && $entry != *\\* ]] ||
      die "the received archive contains an unsafe entry: $entry"
    if [[ $entry != "manifest" &&
      ! $entry =~ ^head-[0-9]{4}-(base|branch|tip|ref|count)$ &&
      ! $entry =~ ^head-[0-9]{4}\.bundle$ ]]; then
      die "the archive contains an unexpected entry: $entry"
    fi
  done
  [[ " ${entries[*]} " == *" manifest "* ]] ||
    die "the archive does not contain exact synchronization metadata"

  unzip -q "$archive" -d "$bundle_directory"
  extracted_entries=("$bundle_directory"/*)
  ((${#extracted_entries[@]} == ${#entries[@]})) ||
    die "the received archive contains duplicate entry names"

  receive_exact_bundle "$bundle_directory" "${#entries[@]}" "$branch" "$base"
}

case "${1:-}" in
send)
  shift
  send_bundle "$@"
  ;;
receive)
  shift
  receive_bundle "$@"
  ;;
--help | -h | help)
  usage
  ;;
"")
  usage >&2
  exit 2
  ;;
*)
  die "unknown command: $1"
  ;;
esac
