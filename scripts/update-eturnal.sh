#!/usr/bin/env bash
set -euo pipefail

fail() {
  echo "update-eturnal: $*" >&2
  exit 1
}

(($# == 0)) || fail "this command takes no arguments"
((EUID != 0)) || fail "refusing to run as root"

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
pins_file="$repo_root/packages/eturnal/pins.json"
git -C "$repo_root" ls-files --error-unmatch -- packages/eturnal/pins.json >/dev/null 2>&1 ||
  fail "eturnal pins file must be tracked by Git"
[[ -z $(git -C "$repo_root" status --porcelain --untracked-files=no) ]] ||
  fail "tracked changes must be committed or stashed first"

printf '\n==> Finding the latest eturnal release\n'
version=$(gh release view --repo processone/eturnal --json tagName --jq .tagName)
# Eturnal release tags are currently unsigned. Trust is deliberately limited to
# the official processone repository; GitHub resolves the release tag to the
# commit that is pinned below.
commit=$(gh api "repos/processone/eturnal/commits/$version" --jq .sha)
[[ $commit =~ ^[0-9a-f]{40}$ ]] || fail "release tag did not resolve to a commit"

printf '\n==> Prefetching eturnal %s (%s)\n' "$version" "$commit"
source=$(nix store prefetch-file --json --unpack \
  "https://github.com/processone/eturnal/archive/$commit.tar.gz")
src_hash=$(jq --exit-status --raw-output .hash <<<"$source")
source_path=$(jq --exit-status --raw-output .storePath <<<"$source")
[[ -d $source_path ]] || fail "prefetched source is not an unpacked directory"
[[ -f $source_path/rebar.lock ]] || fail "prefetched source tree has no rebar.lock"

current_version=$(jq --exit-status --raw-output .version "$pins_file")
current_commit=$(jq --exit-status --raw-output .commit "$pins_file")
current_src_hash=$(jq --exit-status --raw-output .srcHash "$pins_file")
if [[ $version == "$current_version" && $commit == "$current_commit" && $src_hash == "$current_src_hash" ]]; then
  printf 'eturnal %s at %s is already up to date (upstream rebar.lock present)\n' \
    "$version" "$commit"
  exit 0
fi

# fetchRebar3Deps consumes this exact source and its upstream rebar.lock. Force a
# fixed-output mismatch so Nix computes the locked dependency set's new hash;
# the package runs Rebar's get-deps against that lock, never a lock update.
fake_hash="sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
temporary=$(mktemp "${pins_file}.update.XXXXXX")
jq \
  --arg version "$version" \
  --arg commit "$commit" \
  --arg srcHash "$src_hash" \
  --arg depsHash "$fake_hash" \
  '.version = $version | .commit = $commit | .srcHash = $srcHash | .depsHash = $depsHash' \
  "$pins_file" >"$temporary"
chmod --reference="$pins_file" "$temporary"
mv -- "$temporary" "$pins_file"

printf '\n==> Calculating the Rebar3 dependency hash\n'
set +e
build_output=$(nix build --no-link "git+file://$repo_root#eturnal" 2>&1)
build_status=$?
set -e
((build_status != 0)) || fail "placeholder dependency hash was unexpectedly accepted"

deps_hash=$(printf '%s\n' "$build_output" |
  sed -n 's/^[[:space:]]*got:[[:space:]]*\(sha256-[A-Za-z0-9+\/=]*\).*$/\1/p' |
  tail -n 1)
if [[ -z $deps_hash ]]; then
  printf '%s\n' "$build_output" >&2
  fail "could not determine the Rebar3 dependency hash"
fi

temporary=$(mktemp "${pins_file}.update.XXXXXX")
jq --arg depsHash "$deps_hash" '.depsHash = $depsHash' "$pins_file" >"$temporary"
chmod --reference="$pins_file" "$temporary"
mv -- "$temporary" "$pins_file"

git -C "$repo_root" diff --stat -- packages/eturnal
git -C "$repo_root" diff -- packages/eturnal
