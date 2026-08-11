#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: update-flake.sh

Update all flake inputs, regenerate tracked files derived from those inputs,
and evaluate the flake outputs. This changes flake.lock and may change
host-specific generated files, but does not build or deploy a NixOS system.

Run this script as a normal user from any directory. Tracked changes must be
committed or stashed first; unrelated untracked files are allowed.
EOF
}

fail() {
  echo "update-flake: $*" >&2
  exit 1
}

log() {
  printf '\n==> %s\n' "$*"
}

(($# == 0)) || {
  case ${1-} in
  -h | --help)
    usage
    exit 0
    ;;
  esac
  usage >&2
  fail "this command takes no arguments"
}

((EUID != 0)) || fail "refusing to run as root"

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
repo_root=$(cd -- "$script_dir/.." && pwd -P)
[[ -f "$repo_root/flake.nix" ]] || fail "flake.nix not found in repository root: $repo_root"

git -C "$repo_root" diff --quiet --ignore-submodules -- ||
  fail "tracked worktree changes must be committed or stashed first"
git -C "$repo_root" diff --cached --quiet --ignore-submodules -- ||
  fail "staged changes must be committed or stashed first"

cd -- "$repo_root"

log "Updating flake inputs"
nix flake update

log "Regenerating hosts/incus-01/kernel.config"
config_output=$(nix build --no-link --print-out-paths \
  "path:$repo_root#nixosConfigurations.incus-01.config.system.build.kernelConfig")
mapfile -t config_outputs <<<"$config_output"
((${#config_outputs[@]} == 1)) || fail "kernelConfig did not return exactly one output path"
generated_config=${config_outputs[0]}
[[ $generated_config == /nix/store/* && -f $generated_config ]] ||
  fail "kernelConfig returned an unexpected output: $generated_config"

tmp_config=$(mktemp "$repo_root/hosts/incus-01/.kernel.config.XXXXXXXX")
cleanup() {
  rm -f -- "$tmp_config"
}
trap cleanup EXIT
install -m 0644 -- "$generated_config" "$tmp_config"
mv -f -- "$tmp_config" "$repo_root/hosts/incus-01/kernel.config"

log "Evaluating flake outputs"
nix flake check --no-build "path:$repo_root"

log "Update complete"
git -C "$repo_root" diff --stat -- flake.lock hosts/incus-01/kernel.config
git -C "$repo_root" diff -- flake.lock hosts/incus-01/kernel.config
