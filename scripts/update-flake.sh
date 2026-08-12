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

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
[[ -f "$repo_root/flake.nix" ]] || fail "flake.nix not found in repository root: $repo_root"

[[ -z $(git -C "$repo_root" status --porcelain --untracked-files=no) ]] ||
  fail "tracked changes must be committed or stashed first"

cd -- "$repo_root"

log "Updating flake inputs"
nix flake update

shopt -s nullglob
kernel_configs=(hosts/*/kernel.config)

for config_file in "${kernel_configs[@]}"; do
  configuration=$(basename "$(dirname "$config_file")")
  log "Regenerating $config_file"
  generated=$(nix build --no-link --print-out-paths \
    "path:$repo_root#nixosConfigurations.$configuration.config.system.build.kernelConfig")
  install -m 0644 "$generated" "$config_file"
done

log "Files updated"
git -C "$repo_root" diff --stat -- flake.lock "${kernel_configs[@]}"
git -C "$repo_root" diff -- flake.lock "${kernel_configs[@]}"
