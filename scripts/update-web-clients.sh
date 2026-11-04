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
[[ -z $(git -C "$repo_root" status --porcelain --untracked-files=no) ]] ||
  fail "tracked changes must be committed or stashed first"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

upstream=https://git.sable.moe/SableClient/sable-next
log "Resolving the latest stable Sable release"
curl --fail --silent --show-error --location --retry 3 --max-time 60 \
  https://git.sable.moe/api/v1/repos/SableClient/sable-next/releases/latest >"$tmp/release.json"
tag=$(jq -er 'select(.draft == false and .prerelease == false) | .tag_name' "$tmp/release.json") ||
  fail "latest release is not a published stable release"
[[ $tag =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "unexpected stable release tag: $tag"
version=${tag#v}
current_version=$(nix eval --raw --no-update-lock-file "path:$repo_root#sable.version")
if [[ $version == "$current_version" ]]; then
  echo "Sable $version is already up to date."
  exit 0
fi
[[ $(printf '%s\n' "$version" "$current_version" | sort -V | head -n 1) == "$current_version" ]] ||
  fail "refusing to downgrade Sable $current_version to $version"

nix flake metadata --json "git+$upstream?ref=refs/tags/$tag&shallow=1" >"$tmp/source.json"
rev=$(jq -er '.locked.rev' "$tmp/source.json")
[[ $rev =~ ^[0-9a-f]{40}$ ]] || fail "release did not resolve to a Git commit"
source_path=$(jq -er '.path' "$tmp/source.json")
[[ $(jq -er .version "$source_path/package.json") == "$version" ]] ||
  fail "release tag and package version disagree"
url="git+$upstream?ref=refs/tags/$tag&rev=$rev&shallow=1"

log "Pinning Sable $version at $rev (no main-branch or hash-rewrite fallback)"
awk -v url="$url" '
  /^[[:space:]]*sable-next\.url = ".*";$/ {
    print "    sable-next.url = \"" url "\";"
    count++
    next
  }
  { print }
  END { if (count != 1) exit 1 }
' "$repo_root/flake.nix" >"$tmp/flake.nix" ||
  fail "expected exactly one sable-next.url declaration"
install -m 0644 "$tmp/flake.nix" "$repo_root/flake.nix"
(
  cd -- "$repo_root"
  # The changed input brings its own upstream lock; unrelated inputs stay pinned.
  nix flake lock
)

log "Building the configured Sable site, CSP and review diffs"
nix build --no-link --max-jobs 1 --cores 2 \
  "path:$repo_root#nixosConfigurations.nginx.config.system.build.sable"

git -C "$repo_root" diff --stat -- flake.nix flake.lock
git -C "$repo_root" diff -- flake.nix flake.lock
