#!/usr/bin/env bash
set -euo pipefail

fail() {
  echo "update-eturnal: $*" >&2
  exit 1
}

(($# == 0)) || fail "this command takes no arguments"
((EUID != 0)) || fail "refusing to run as root"

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
target_paths=(packages/eturnal/{pins.json,rebar.lock})
pins_file="$repo_root/${target_paths[0]}"
lock_file="$repo_root/${target_paths[1]}"

git -C "$repo_root" ls-files --error-unmatch -- "${target_paths[@]}" >/dev/null 2>&1 ||
  fail "eturnal pins and lock files must be tracked by Git"
[[ -z $(git -C "$repo_root" status --porcelain --untracked-files=no) ]] ||
  fail "tracked changes must be committed or stashed first"

tmp_dir=$(mktemp -d)
cleanup() {
  status=$?
  if ((status != 0)); then
    git -C "$repo_root" restore --source=HEAD --worktree -- "${target_paths[@]}" &&
      message="restored original files" || message="automatic restore failed; use git restore"
    echo "update-eturnal: update failed; $message" >&2
  fi
  rm -rf "$tmp_dir"
  return "$status"
}
trap cleanup EXIT

printf '\n==> Finding the latest eturnal release\n'
version=$(curl --fail --silent --show-error --location \
  https://api.github.com/repos/processone/eturnal/releases/latest |
  jq --exit-status --raw-output '.tag_name')
[[ "$version" =~ ^[0-9A-Za-z][0-9A-Za-z._-]*$ ]] || fail "invalid release version: $version"
current_version=$(jq --exit-status --raw-output '.version' "$pins_file")
if [[ "$version" == "$current_version" ]]; then
  printf 'eturnal %s is already up to date\n' "$version"
  exit 0
fi

printf '\n==> Fetching eturnal %s\n' "$version"
src_hash=$(nix store prefetch-file --json --unpack \
  "https://github.com/processone/eturnal/archive/refs/tags/$version.tar.gz" |
  jq --exit-status --raw-output '.hash')
curl --fail --silent --show-error --location \
  "https://raw.githubusercontent.com/processone/eturnal/$version/rebar.lock" \
  --output "$tmp_dir/rebar.lock"
grep -q '^{"1\.2\.0",' "$tmp_dir/rebar.lock" || fail "unexpected rebar.lock format"
install -m 0644 "$tmp_dir/rebar.lock" "$lock_file"

# Force a fixed-output hash mismatch so Nix reports the new dependency hash.
fake_hash="sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
jq \
  --arg version "$version" \
  --arg srcHash "$src_hash" \
  --arg depsHash "$fake_hash" \
  '.version = $version | .srcHash = $srcHash | .depsHash = $depsHash' \
  "$pins_file" >"$tmp_dir/pins.json"
install -m 0644 "$tmp_dir/pins.json" "$pins_file"

printf '\n==> Calculating the Rebar3 dependency hash\n'
set +e
build_output=$(nix build --no-link "path:$repo_root#eturnal" 2>&1)
build_status=$?
set -e
((build_status != 0)) || fail "placeholder dependency hash was unexpectedly accepted"

deps_hash=$(printf '%s\n' "$build_output" |
  sed -n 's/^[[:space:]]*got:[[:space:]]*\(sha256-[A-Za-z0-9+\/=]*\).*$/\1/p' |
  tail -n 1)
if [[ -z "$deps_hash" ]]; then
  printf '%s\n' "$build_output" >&2
  fail "could not determine the Rebar3 dependency hash"
fi

jq --arg depsHash "$deps_hash" '.depsHash = $depsHash' \
  "$pins_file" >"$tmp_dir/pins.json"
install -m 0644 "$tmp_dir/pins.json" "$pins_file"

printf '\n==> Building eturnal %s\n' "$version"
nix build --no-link "path:$repo_root#eturnal"

git -C "$repo_root" diff --stat -- packages/eturnal
git -C "$repo_root" diff -- packages/eturnal
