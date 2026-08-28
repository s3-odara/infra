#!/usr/bin/env bash
set -euo pipefail

fail() {
  echo "update-web-clients: $*" >&2
  exit 1
}

log() {
  printf '\n==> %s\n' "$*"
}

(($# == 0)) || fail "this command takes no arguments"
((EUID != 0)) || fail "refusing to run as root"

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
pins="$repo_root/packages/sable/pins.json"
relative_pins=${pins#"$repo_root/"}
[[ -f $pins ]] || fail "required tracked file is missing: $relative_pins"
git -C "$repo_root" ls-files --error-unmatch -- "$relative_pins" >/dev/null 2>&1 ||
  fail "Sable pin file must be tracked by Git"
[[ -z $(git -C "$repo_root" status --porcelain --untracked-files=no) ]] ||
  fail "tracked changes must be committed or stashed first"

current=$(jq --exit-status --raw-output '.version' "$pins") || fail "invalid Sable pin"
release=$(curl --fail --silent --show-error --location \
  "https://api.github.com/repos/SableClient/Sable/releases/latest")
version=$(jq --exit-status --raw-output '.tag_name | sub("^v"; "")' <<<"$release")

if [[ $version == "$current" ]]; then
  printf 'Sable %s is already up to date.\n' "$version"
  exit 0
fi

log "Updating the Sable OCI pin to $version"
image=$(nix-prefetch-docker --json --quiet --os linux --arch amd64 \
  ghcr.io/sableclient/sable "$version")
temporary=$(mktemp "${pins}.update.XXXXXX")
trap 'rm -f -- "$temporary"' EXIT
jq \
  --arg version "$version" \
  --arg imageDigest "$(jq --exit-status --raw-output '.imageDigest' <<<"$image")" \
  --arg imageHash "$(jq --exit-status --raw-output '.hash' <<<"$image")" \
  '.version = $version | .imageDigest = $imageDigest | .imageHash = $imageHash' \
  "$pins" >"$temporary"
chmod --reference="$pins" "$temporary"
mv -- "$temporary" "$pins"
trap - EXIT

log "Building the unwrapped Sable OCI artifact"
sable_unwrapped=$(nix build --no-link --print-out-paths "path:$repo_root#sable")
printf 'Unwrapped Sable: %s\n' "$sable_unwrapped"

log "Updated pin"
git -C "$repo_root" diff --stat -- "$relative_pins"
git -C "$repo_root" diff -- "$relative_pins"

cat <<EOF

The pin update is intentionally left in the working tree. The configured root
and Nginx closure have not been built because the version-bound HTML SHA gates
must be refreshed first:
  1. Copy $sable_unwrapped/index.html and
     $sable_unwrapped/public/element-call/index.html to temporary files.
  2. Calculate sha256sum for both original files.
  3. Copy the originals to temporary files and make only the documented
     inline-script substitutions.
  4. Review diff -u from each original to its patched temporary file, then
     refresh guests/nginx/web-client-patches/sable-$version.patch.
  5. Update the patch filename reference and both adjacent SHA-256 constants
     in guests/nginx/configuration.nix.
  6. Build the configured root:
     nix build --no-link 'path:$repo_root#nixosConfigurations.nginx.config.services.nginx.virtualHosts."sable.matrix.odarah.org".root'
  7. Build the Nginx closure:
     nix build --no-link 'path:$repo_root#nixosConfigurations.nginx.config.system.build.toplevel'
EOF
