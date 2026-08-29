#!/usr/bin/env bash
set -euo pipefail

fail() {
  echo "update-sygnal: $*" >&2
  exit 1
}

(($# == 0)) || fail "this command takes no arguments"
((EUID != 0)) || fail "refusing to run as root"

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
pins="$repo_root/packages/sygnal/pins.json"
relative_pins=${pins#"$repo_root/"}

git -C "$repo_root" ls-files --error-unmatch -- "$relative_pins" >/dev/null 2>&1 ||
  fail "Sygnal pins file must be tracked by Git"
[[ -z $(git -C "$repo_root" status --porcelain --untracked-files=no) ]] ||
  fail "tracked changes must be committed or stashed first"

current=$(jq --exit-status --raw-output '.version' "$pins") || fail "invalid Sygnal pin"
release=$(curl --fail --silent --show-error --location \
  https://api.github.com/repos/element-hq/sygnal/releases/latest)
tag=$(jq --exit-status --raw-output '.tag_name' <<<"$release")
[[ $tag == v* ]] || fail "unexpected release tag: $tag"
version=${tag#v}

if [[ $version == "$current" ]]; then
  printf 'Sygnal %s is already up to date.\n' "$version"
  exit 0
fi

printf '\n==> Updating Sygnal to %s\n' "$version"
src_hash=$(nix store prefetch-file --json --unpack \
  "https://github.com/element-hq/sygnal/archive/refs/tags/$tag.tar.gz" |
  jq --exit-status --raw-output '.hash')

temporary=$(mktemp "${pins}.update.XXXXXX")
trap 'rm -f -- "$temporary"' EXIT
jq \
  --arg version "$version" \
  --arg srcHash "$src_hash" \
  '.version = $version | .srcHash = $srcHash' \
  "$pins" >"$temporary"
chmod --reference="$pins" "$temporary"
mv -- "$temporary" "$pins"
trap - EXIT

printf '\n==> Building Sygnal %s\n' "$version"
nix build --no-link "path:$repo_root#sygnal"

git -C "$repo_root" diff --stat -- "$relative_pins"
git -C "$repo_root" diff -- "$relative_pins"
