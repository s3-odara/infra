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
  packages/commet-web/font-fallbacks.json
  packages/commet-web/git-hashes.json
  packages/commet-web/pins.json
  packages/commet-web/pubspec.lock.json
  packages/sable/pins.json
)
git -C "$repo_root" ls-files --error-unmatch -- "${target_paths[@]}" >/dev/null 2>&1 ||
  fail "web client pin files must be tracked by Git"
[[ -z $(git -C "$repo_root" status --porcelain --untracked-files=no) ]] ||
  fail "tracked changes must be committed or stashed first"

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT
updated_paths=()
commet_inputs_updated=false

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

update_flutter_font_fallbacks() {
  local relative=packages/commet-web/font-fallbacks.json
  local lock="$repo_root/$relative"
  local flutter flutter_version engine_revision source current_revision

  flutter=$(nix eval --impure --raw --expr \
    "(builtins.getFlake \"$repo_root\").inputs.nixpkgs.legacyPackages.x86_64-linux.flutter341.unwrapped")
  flutter_version=$(nix eval --impure --raw --expr \
    "(builtins.getFlake \"$repo_root\").inputs.nixpkgs.legacyPackages.x86_64-linux.flutter341.version")
  engine_revision=$(nix eval --impure --raw --expr \
    "(builtins.getFlake \"$repo_root\").inputs.nixpkgs.legacyPackages.x86_64-linux.flutter341.engineVersion")
  source="$flutter/engine/src/flutter/lib/web_ui/lib/src/engine/font_fallback_data.dart"
  current_revision=$(jq --exit-status --raw-output '.engineRevision' "$lock")
  if [[ "$engine_revision" == "$current_revision" ]]; then
    printf 'Flutter fallback fonts for engine %s are already up to date\n' "$engine_revision"
    return
  fi

  log "Updating Flutter fallback fonts for engine $engine_revision"
  python3 - "$source" "$tmp_dir/font-fallbacks.json" "$flutter_version" "$engine_revision" <<'PY'
import concurrent.futures
import json
import re
import subprocess
import sys
import time
from pathlib import PurePosixPath, Path

source, output, flutter_version, engine_revision = sys.argv[1:]
source_path = Path(source)
entries = re.findall(
    r"NotoFont\(\s*'([^']+)',\s*'([^']+\.woff2)'",
    source_path.read_text(),
)
canvaskit_fonts = source_path.parent / "canvaskit/fonts.dart"
roboto_paths = re.findall(
    r"fontFallbackBaseUrl\}([^']+\.woff2)",
    canvaskit_fonts.read_text(),
)
if len(roboto_paths) != 1:
    raise SystemExit(f"expected one CanvasKit Roboto fallback, got {len(roboto_paths)}")
entries.append(("Roboto", roboto_paths[0]))
paths = [path for _, path in entries]
if not entries or len(paths) != len(set(paths)):
    raise SystemExit("fallback font inventory is empty or contains duplicate paths")
for path in paths:
    parsed = PurePosixPath(path)
    if (
        parsed.is_absolute()
        or ".." in parsed.parts
        or re.fullmatch(r"[A-Za-z0-9._/-]+", path) is None
    ):
        raise SystemExit(f"unsafe fallback font path: {path}")


def prefetch(entry):
    family, path = entry
    url = f"https://fonts.gstatic.com/s/{path}"
    for attempt in range(5):
        result = subprocess.run(
            ["nix", "store", "prefetch-file", "--json", url],
            capture_output=True,
            text=True,
        )
        if result.returncode == 0:
            return path, json.loads(result.stdout)["hash"]
        time.sleep(2**attempt)
    raise RuntimeError(f"failed to prefetch {url}: {result.stderr}")


with concurrent.futures.ThreadPoolExecutor(max_workers=12) as pool:
    hashes = dict(pool.map(prefetch, entries))
lock = {
    "flutterVersion": flutter_version,
    "engineRevision": engine_revision,
    "baseUrl": "https://fonts.gstatic.com/s/",
    "fontCount": len(entries),
    "fonts": [
        {"family": family, "path": path, "hash": hashes[path]}
        for family, path in entries
    ],
}
Path(output).write_text(json.dumps(lock, indent=2) + "\n")
PY
  install -m 0644 "$tmp_dir/font-fallbacks.json" "$lock"
  updated_paths+=("$relative")
  commet_inputs_updated=true
}

update_commet() {
  local relative_dir=packages/commet-web
  local pins="$repo_root/$relative_dir/pins.json"
  local release version current source_url fetched source build_date output hashes git_hash_script

  release=$(latest_release commetchat/commet)
  version=$(jq --exit-status --raw-output '.tag_name | sub("^v"; "")' <<<"$release")
  current=$(jq --exit-status --raw-output '.version' "$pins")
  if [[ "$version" == "$current" ]]; then
    printf 'Commet %s is already up to date\n' "$version"
    [[ "$commet_inputs_updated" == true ]] || return
  else
    log "Updating Commet to $version"
    source_url="https://github.com/commetchat/commet/archive/refs/tags/v${version//+/%2B}.tar.gz"
    fetched=$(nix store prefetch-file --json --unpack "$source_url")
    source=$(jq --exit-status --raw-output '.storePath' <<<"$fetched")
    build_date="$(date --date="$(jq --exit-status --raw-output '.published_at' <<<"$release")" +%s)000"
    jq \
      --arg version "$version" \
      --arg srcHash "$(jq --exit-status --raw-output '.hash' <<<"$fetched")" \
      --arg buildDate "$build_date" \
      '.version = $version | .srcHash = $srcHash | .buildDate = $buildDate' \
      "$pins" >"$tmp_dir/pins.json"
    install -m 0644 "$tmp_dir/pins.json" "$pins"

    yq eval --output-format=json --prettyPrint "$source/pubspec.lock" \
      >"$repo_root/$relative_dir/pubspec.lock.json"
    git_hash_script=$(nix eval --impure --raw --expr \
      "(builtins.getFlake \"$repo_root\").inputs.nixpkgs.legacyPackages.x86_64-linux.dart.fetchGitHashesScript")
    "$git_hash_script" \
      --input "$repo_root/$relative_dir/pubspec.lock.json" \
      --output "$repo_root/$relative_dir/git-hashes.json"
    commet_inputs_updated=true
  fi

  output=$(nix build --no-link --print-out-paths "path:$repo_root#commet-web")
  hashes=$(inline_script_hashes "$output/index.html" "$output/auth.html")
  jq --exit-status 'length > 0' <<<"$hashes" >/dev/null || fail "no inline Commet scripts found"
  jq --argjson hashes "$hashes" '.scriptHashes = $hashes' "$pins" >"$tmp_dir/pins.json"
  install -m 0644 "$tmp_dir/pins.json" "$pins"

  if [[ "$version" != "$current" ]]; then
    updated_paths+=(
      "$relative_dir/git-hashes.json"
      "$relative_dir/pubspec.lock.json"
    )
  fi
  updated_paths+=("$relative_dir/pins.json")
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
update_flutter_font_fallbacks
update_commet
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
