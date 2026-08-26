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
target_paths=(
  packages/conversejs/pins.json
  packages/commet-web/pins.json
  packages/sable/pins.json
)
git -C "$repo_root" ls-files --error-unmatch -- "${target_paths[@]}" >/dev/null 2>&1 ||
  fail "web client pin files must be tracked by Git"
[[ -z $(git -C "$repo_root" status --porcelain --untracked-files=no) ]] ||
  fail "tracked changes must be committed or stashed first"

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT
updated_paths=()

latest_release() {
  curl --fail --silent --show-error --location \
    "https://api.github.com/repos/$1/releases/latest"
}

inline_script_hashes() {
  python3 - "$@" <<'PY'
import base64, hashlib, json, re, sys
from pathlib import Path

hashes = []
for filename in sys.argv[1:]:
    for attrs, body in re.findall(
        rb"<script\b([^>]*)>(.*?)</script\s*>", Path(filename).read_bytes(), re.I | re.S
    ):
        if not re.search(rb"\bsrc\s*=", attrs, re.I):
            digest = base64.b64encode(hashlib.sha256(body).digest()).decode()
            hashes.append(f"sha256-{digest}")
print(json.dumps(hashes, separators=(",", ":")))
PY
}

update_release_asset() {
  local label=$1 repo=$2 relative_pins=$3 package=$4 asset_pattern=$5
  shift 5
  local pins="$repo_root/$relative_pins"
  local release version current asset_name url fetched output hashes relative
  local hash_files=()

  release=$(latest_release "$repo")
  version=$(jq --exit-status --raw-output '.tag_name | sub("^v"; "")' <<<"$release")
  current=$(jq --exit-status --raw-output '.version' "$pins")
  if [[ "$version" == "$current" ]]; then
    printf '%s %s is already up to date\n' "$label" "$version"
    return
  fi

  log "Updating $label to $version"
  asset_name=${asset_pattern//%VERSION%/$version}
  url=$(jq --exit-status --raw-output --arg name "$asset_name" \
    '.assets[] | select(.name == $name) | .browser_download_url' <<<"$release")
  fetched=$(nix store prefetch-file --json "$url")
  jq \
    --arg version "$version" \
    --arg srcHash "$(jq --exit-status --raw-output '.hash' <<<"$fetched")" \
    '.version = $version | .srcHash = $srcHash' "$pins" >"$tmp_dir/pins.json"
  install -m 0644 "$tmp_dir/pins.json" "$pins"

  if (($# > 0)); then
    output=$(nix build --no-link --print-out-paths "path:$repo_root#$package")
    for relative in "$@"; do
      hash_files+=("$output/$relative")
    done
    hashes=$(inline_script_hashes "${hash_files[@]}")
    jq --exit-status 'length > 0' <<<"$hashes" >/dev/null || fail "no inline $label scripts found"
    jq --argjson hashes "$hashes" '.scriptHashes = $hashes' "$pins" >"$tmp_dir/pins.json"
    install -m 0644 "$tmp_dir/pins.json" "$pins"
  fi
  updated_paths+=("$relative_pins")
}

update_sable() {
  local relative_pins=packages/sable/pins.json
  local pins="$repo_root/$relative_pins"
  local release version current image output hashes

  release=$(latest_release SableClient/Sable)
  version=$(jq --exit-status --raw-output '.tag_name | sub("^v"; "")' <<<"$release")
  current=$(jq --exit-status --raw-output '.version' "$pins")
  if [[ "$version" == "$current" ]]; then
    printf 'Sable %s is already up to date\n' "$version"
    return
  fi

  log "Updating Sable to $version"
  image=$(nix-prefetch-docker --json --quiet --os linux --arch amd64 \
    ghcr.io/sableclient/sable "$version")
  jq \
    --arg version "$version" \
    --arg imageDigest "$(jq --exit-status --raw-output '.imageDigest' <<<"$image")" \
    --arg imageHash "$(jq --exit-status --raw-output '.hash' <<<"$image")" \
    '.version = $version | .imageDigest = $imageDigest | .imageHash = $imageHash' \
    "$pins" >"$tmp_dir/pins.json"
  install -m 0644 "$tmp_dir/pins.json" "$pins"

  output=$(nix build --no-link --print-out-paths "path:$repo_root#sable")
  hashes=$(inline_script_hashes "$output/index.html")
  jq --exit-status 'length > 0' <<<"$hashes" >/dev/null || fail "no inline Sable scripts found"
  jq --argjson hashes "$hashes" '.scriptHashes = $hashes' "$pins" >"$tmp_dir/pins.json"
  install -m 0644 "$tmp_dir/pins.json" "$pins"
  updated_paths+=("$relative_pins")
}

log "Checking for Web client updates"
update_release_asset \
  Converse.js conversejs/converse.js packages/conversejs/pins.json conversejs \
  'converse.js-%VERSION%.tgz'
update_release_asset \
  Commet commetchat/commet packages/commet-web/pins.json commet-web \
  commet-web.tar.gz index.html auth.html
update_sable

if ((${#updated_paths[@]} == 0)); then
  printf '\nAll Web clients are already up to date.\n'
  exit 0
fi

log "Building Web clients and Nginx configuration"
nix build --no-link \
  "path:$repo_root#conversejs" \
  "path:$repo_root#commet-web" \
  "path:$repo_root#sable" \
  "path:$repo_root#nixosConfigurations.nginx.config.system.build.toplevel"

log "Updated files"
git -C "$repo_root" diff --stat -- "${updated_paths[@]}"
git -C "$repo_root" diff -- "${updated_paths[@]}"
