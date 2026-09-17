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
key_file="$repo_root/packages/sygnal/signing-key.asc"
fingerprint_file="$repo_root/packages/sygnal/signing-key.fingerprint"
[[ -z $(git -C "$repo_root" status --porcelain --untracked-files=no) ]] ||
  fail "tracked changes must be committed or stashed first"
[[ -r $key_file ]] || fail "pinned signing key is missing: $key_file"
[[ -r $fingerprint_file ]] || fail "pinned signing fingerprint is missing: $fingerprint_file"
approved=$(<"$fingerprint_file")
[[ $(wc -l <"$fingerprint_file") -eq 1 && $approved =~ ^[0-9A-F]{40}$ ]] ||
  fail "pinned fingerprint must be one uppercase 40-hex line"

tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
export GNUPGHOME="$tmp/gnupg"
mkdir -m 0700 "$GNUPGHOME"
gpg --batch --import "$key_file" >/dev/null 2>&1 || fail "could not import pinned Sygnal key"
key_listing=$(gpg --batch --with-colons --list-keys --fingerprint)
imported_primaries=$(awk -F: '
  $1 == "pub" { primary = 1; next }
  primary && $1 == "fpr" { print toupper($10); primary = 0 }
' <<<"$key_listing")
[[ $imported_primaries == "$approved" ]] || fail "pinned key primary fingerprint does not match"

tag=$(gh release view --repo element-hq/sygnal --json tagName --jq .tagName)
version=${tag#v}
[[ $tag == v* && -n $version ]] || fail "unexpected release tag: $tag"

git -C "$tmp" init -q repo
git -C "$tmp/repo" remote add origin https://github.com/element-hq/sygnal.git
git -C "$tmp/repo" fetch -q --no-tags origin "refs/tags/$tag:refs/tags/$tag" ||
  fail "could not fetch release tag"
if ! git -C "$tmp/repo" verify-tag --raw "$tag" >"$tmp/verify-status" 2>&1; then
  cat "$tmp/verify-status" >&2
  fail "signed tag verification failed (no unsigned fallback)"
fi
cat "$tmp/verify-status" >&2

# This repository intentionally permits EXPKEYSIG and its KEYEXPIRED notices
# for this pinned key: its signing subkey expired before the verified v0.17.0
# release, and no refreshed certificate was found. The cryptographic signature,
# successful verify-tag status, and pinned primary fingerprint remain mandatory.
if awk '$1 == "[GNUPG:]" && ($2 == "REVKEYSIG" || $2 == "EXPSIG") { found = 1 }
        END { exit !found }' "$tmp/verify-status"; then
  fail "revoked keys and expired signatures are not permitted"
fi
awk -v approved="$approved" '
  $1 == "[GNUPG:]" && $2 == "VALIDSIG" && toupper($NF) == approved { valid = 1 }
  END { exit !valid }
' "$tmp/verify-status" || fail "tag was not signed by the pinned primary fingerprint"

commit=$(git -C "$tmp/repo" rev-parse "$tag^{commit}")
[[ $commit =~ ^[0-9a-f]{40}$ ]] || fail "tag did not resolve to a commit"
git -C "$tmp/repo" checkout -q --detach "$commit"

current_commit=$(jq -er .commit "$pins")
[[ $current_commit =~ ^[0-9a-f]{40}$ ]] || fail "current Sygnal commit pin is invalid"
git -C "$tmp/repo" fetch -q --no-tags origin "$current_commit"
for file in poetry.lock pyproject.toml; do
  git -C "$tmp/repo" show "$current_commit:$file" >"$tmp/old-$file" ||
    fail "could not read $file from current pinned commit"
done

# Show only the handwritten-pin lock entries and the six locally relevant
# constraints, then check (without rewriting) all four handwritten pins.
check-sygnal-pins \
  "$tmp/old-poetry.lock" \
  "$tmp/old-pyproject.toml" \
  "$tmp/repo/poetry.lock" \
  "$tmp/repo/pyproject.toml" \
  "$pins"

source=$(nix store prefetch-file --json --unpack \
  "https://github.com/element-hq/sygnal/archive/$commit.tar.gz")
src_hash=$(jq -er .hash <<<"$source")
current_version=$(jq -er .version "$pins")
current_src_hash=$(jq -er .srcHash "$pins")
if [[ $version == "$current_version" && $commit == "$current_commit" && $src_hash == "$current_src_hash" ]]; then
  printf 'Sygnal %s at %s is already up to date; four handwritten pins match.\n' "$version" "$commit"
  exit 0
fi

out=$(mktemp "${pins}.update.XXXXXX")
jq --arg version "$version" --arg commit "$commit" --arg srcHash "$src_hash" \
  '.version = $version | .commit = $commit | .srcHash = $srcHash' "$pins" >"$out"
chmod --reference="$pins" "$out"
mv -- "$out" "$pins"

git -C "$repo_root" diff --stat -- packages/sygnal
git -C "$repo_root" diff -- packages/sygnal
