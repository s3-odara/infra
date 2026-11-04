#!/usr/bin/env bash
# Run on the management terminal, not on the target host.
set -euo pipefail

usage() {
  printf 'Usage: bash collect-logs.sh HOST [LOCAL_PARENT]\n' >&2
  printf '       bash collect-logs.sh --fetch HOST REMOTE_DIRECTORY [LOCAL_PARENT]\n' >&2
}
validate_directory() {
  [[ $1 =~ ^/[a-zA-Z0-9_./-]+$ && /$1/ != *'/../'* ]] || {
    echo 'Expected a safe absolute collection directory.' >&2
    exit 2
  }
}
fetch_results() {
  local source=$1 result
  validate_directory "$source"
  mkdir -p -- "$parent"
  result=$(mktemp -d "$parent/$host.XXXXXXXXXX")
  printf 'Receiving into %s\n' "$result" >&2
  scp "${ssh_options[@]}" \
    "$host:$source/collection.tar.zst" "$result/collection.tar.zst.partial"
  zstd --quiet --test "$result/collection.tar.zst.partial"
  mv -- "$result/collection.tar.zst.partial" "$result/collection.tar.zst"
  printf 'received_utc=%s\nsource=%s:%s\ntransfer_exit=0\ncompression=zstd\ncompression_check=passed\n' \
    "$(date -u +%FT%TZ)" "$host" "$source" >"$result/receipt.txt"
  printf 'Archive received (zstd format check only): %s/collection.tar.zst\n' "$result"
  printf 'Not extracted. Inspect collection metadata for incomplete acquisition.\n'
}

mode=collect
if [[ ${1:-} == --help ]]; then
  usage
  exit 0
elif [[ ${1:-} == --fetch ]]; then
  mode=fetch
  shift
  (($# >= 2 && $# <= 3)) || {
    usage
    exit 2
  }
  host=$1
  remote_result=${2%/}
  validate_directory "$remote_result"
  parent=${3:-log-collections}
else
  (($# >= 1 && $# <= 2)) || {
    usage
    exit 2
  }
  host=$1
  parent=${2:-log-collections}
fi
[[ $host =~ ^[a-zA-Z0-9][a-zA-Z0-9_.@-]*$ ]] || {
  echo 'Invalid SSH destination' >&2
  exit 2
}
command -v zstd >/dev/null || {
  echo 'zstd is required locally (nothing will be installed).' >&2
  exit 1
}
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
umask 077
control=$(mktemp -d "${TMPDIR:-/tmp}/log-collection-ssh.XXXXXXXXXX")
ssh_options=(
  -o BatchMode=yes
  -o ConnectTimeout=15
  -o StrictHostKeyChecking=yes
  -o UpdateHostKeys=no
  -o ControlMaster=auto
  -o ControlPersist=60s
  -o "ControlPath=$control/%C"
)
ssh_remote() {
  # shellcheck disable=SC2029 # Commands are fixed or use validated, quoted paths.
  ssh "${ssh_options[@]}" "$@"
}
# shellcheck disable=SC2329 # Invoked by the EXIT trap.
cleanup() {
  ssh_remote -O exit "$host" >/dev/null 2>&1 || true
  rm -rf -- "$control"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

if [[ $mode == fetch ]]; then
  fetch_results "$remote_result"
  exit 0
fi
# shellcheck disable=SC2016 # Inspect the remote environment and use its HOME.
remote_dir=$(ssh_remote -T "$host" '
  set -eu
  test "$(id -u)" -ne 0
  for tool in nixos-version incus zstd; do
    PATH=/run/current-system/sw/bin:/run/wrappers/bin:/usr/bin:/bin command -v "$tool" >/dev/null || {
      echo "$tool is required on the target (nothing will be installed)." >&2
      exit 1
    }
  done
  umask 077
  mktemp -d "$HOME/log-collection.XXXXXXXXXX"
')
validate_directory "$remote_dir"
[[ ${remote_dir##*/} =~ ^log-collection\.[[:alnum:]]+$ ]] || {
  echo 'Unexpected remote staging directory; collection not started.' >&2
  exit 1
}
printf 'Remote script: %s/collect-logs-remote.sh\nRemote results: %s/results\n' "$remote_dir" "$remote_dir"
tar -C "$script_dir" -cf - collect-logs-remote.sh |
  ssh_remote -T "$host" "umask 077; tar -C '$remote_dir' -xf -"
printf -v remote_command 'bash %q %q' "$remote_dir/collect-logs-remote.sh" "$remote_dir/results"
remote_status=0
# The PTY is for doas only. Binary output stays in remote files, not the PTY.
if ssh_remote -t "$host" "$remote_command"; then
  remote_status=0
else
  remote_status=$?
  printf 'Remote collection exited %s; attempting to fetch its partial result.\n' "$remote_status" >&2
fi
fetch_results "$remote_dir/results"
exit "$remote_status"
