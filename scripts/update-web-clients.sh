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
[[ -z $(git -C "$repo_root" status --porcelain --untracked-files=no) ]] ||
  fail "tracked changes must be committed or stashed first"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

tag=$(gh release view --repo SableClient/Sable --json tagName --jq .tagName)
version=${tag#v}
[[ $tag == v* && -n $version ]] || fail "unexpected release tag: $tag"

log "Resolving the official Sable OCI index for $tag"
skopeo inspect --raw "docker://ghcr.io/sableclient/sable:$version" >"$tmp/index.json"
jq -e '.manifests | type == "array" and length > 0' "$tmp/index.json" >/dev/null ||
  fail "release tag is not an OCI index"
digest="sha256:$(sha256sum "$tmp/index.json" | cut -d' ' -f1)"

log "Verifying GitHub artifact attestation for $digest"
gh attestation verify "oci://ghcr.io/sableclient/sable@$digest" \
  --repo SableClient/Sable \
  --signer-workflow SableClient/Sable/.github/workflows/docker-publish.yml >/dev/null ||
  fail "attestation verification failed (no digest-only fallback)"

current_version=$(jq -er .version "$pins")
current_digest=$(jq -er .imageDigest "$pins")
if [[ $version == "$current_version" && $digest == "$current_digest" ]]; then
  echo "Sable $version at $digest is already up to date."
  exit 0
fi

log "Prefetching the verified index for linux/amd64"
image=$(nix-prefetch-docker --json --quiet --os linux --arch amd64 \
  --final-image-tag "$version" ghcr.io/sableclient/sable "$digest")
[[ $(jq -er .imageDigest <<<"$image") == "$digest" ]] ||
  fail "prefetch changed the verified digest"
hash=$(jq -er .hash <<<"$image")

temporary=$(mktemp "${pins}.update.XXXXXX")
jq --arg version "$version" --arg imageDigest "$digest" --arg imageHash "$hash" \
  '.version = $version | .imageDigest = $imageDigest | .imageHash = $imageHash' \
  "$pins" >"$temporary"
chmod --reference="$pins" "$temporary"
mv -- "$temporary" "$pins"

git -C "$repo_root" diff --stat -- packages/sable
git -C "$repo_root" diff -- packages/sable
