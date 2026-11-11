#!/usr/bin/env bash
set -euo pipefail

[[ ${GITHUB_ACTIONS:-} == true ]] || {
  echo "install-nix: refusing to run outside GitHub Actions" >&2
  exit 1
}
[[ ${RUNNER_OS:-} == Linux ]] || {
  echo "install-nix: unsupported runner OS: ${RUNNER_OS:-unknown}" >&2
  exit 1
}
: "${GITHUB_PATH:?GITHUB_PATH is required}"
: "${GH_TOKEN:?GH_TOKEN is required}"

repository=NixOS/nix-installer
artifact=nix-installer-x86_64-linux
installer_dir=$RUNNER_TEMP/nix-installer
installer=$installer_dir/$artifact

version=$(gh release view --repo "$repository" --json tagName --jq .tagName)

mkdir -p "$installer_dir"
gh release download "$version" \
  --repo "$repository" \
  --dir "$installer_dir" \
  --pattern "$artifact"
gh attestation verify "$installer" \
  --repo "$repository" \
  --signer-workflow NixOS/nix-installer/.github/workflows/release-script.yml
chmod +x "$installer"

install_args=(
  install
  linux
  --no-confirm
  --enable-flakes
)

# Upstream flakes provide package definitions, not additional cache trust anchors.
extra_conf='accept-flake-config = false'
cache_name=${CACHIX_CACHE_NAME:-}
public_key=${CACHIX_PUBLIC_KEY:-}
if [[ -n $cache_name || -n $public_key ]]; then
  : "${cache_name:?CACHIX_CACHE_NAME is required when configuring Cachix}"
  : "${public_key:?CACHIX_PUBLIC_KEY is required when configuring Cachix}"

  extra_conf=$(printf '%s\n%s\n%s' \
    "$extra_conf" \
    "extra-substituters = https://$cache_name.cachix.org" \
    "extra-trusted-public-keys = $public_key")
fi
install_args+=(--extra-conf "$extra_conf")

sudo "$installer" "${install_args[@]}"
printf '%s\n' /nix/var/nix/profiles/default/bin >>"$GITHUB_PATH"
