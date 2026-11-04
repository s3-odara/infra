#!/usr/bin/env bash
# Local fixtures only. SSH/SCP are mocked; no root or Incus operations run.
set -euo pipefail
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
temporary=$(mktemp -d)
trap 'rm -rf -- "$temporary"' EXIT
umask 077

# shellcheck source-path=SCRIPTDIR/..
# shellcheck source=collect-logs-remote.sh
source "$script_dir/collect-logs-remote.sh"

# Outside, broken and looping links are reported; in-scope links are not.
log_dir=$temporary/logs
mkdir -- "$log_dir" "$temporary/logs-extra"
printf 'retained log\n' >"$log_dir/local.log"
printf 'outside contents must not be collected\n' >"$temporary/logs-extra/external.log"
ln -s local.log "$log_dir/inside"
ln -s ../logs-extra/external.log "$log_dir/outside link"
ln -s missing.log "$log_dir/broken"
ln -s loop "$log_dir/loop"
bash -c "$log_symlinks" bash "$log_dir" >"$temporary/links.tsv"
awk -F '\t' '
  $1 == "outside" { outside++ }
  $1 == "unresolved" { unresolved++ }
  END { exit !(outside == 1 && unresolved == 2 && NR == 4) }
' "$temporary/links.tsv"
printf -v expected 'outside\t%q\t%q\t%q' \
  "$log_dir/outside link" ../logs-extra/external.log "$temporary/logs-extra/external.log"
grep -Fx -- "$expected" "$temporary/links.tsv" >/dev/null
TAR_OPTIONS=--dereference bash -c "$raw_logs" bash "$log_dir" >"$temporary/logs.tar"
tar -tvf "$temporary/logs.tar" | awk '$1 ~ /^l/ { links++ } END { exit links != 4 }'
[[ $(tar -xOf "$temporary/logs.tar" "${log_dir#/}/local.log") == 'retained log' ]]

# A log root that is itself a symlink must not be mistaken for covered data.
ln -s "$log_dir" "$temporary/linked-logs"
bash -c "$log_symlinks" bash "$temporary/linked-logs" >"$temporary/root-link.tsv"
awk -F '\t' 'NR == 2 { found=($1 == "outside") } END { exit !(found && NR == 2) }' "$temporary/root-link.tsv"
bash -c "$raw_logs" bash "$temporary/linked-logs" >"$temporary/root-link.tar"
tar -tvf "$temporary/root-link.tar" | awk 'NR == 1 { found=($1 ~ /^l/) } END { exit !(found && NR == 1) }'

# Check error recording and discovery using names unrelated to any real host.
work=$temporary/status
mkdir -- "$work"
failures=0
capture failed.txt 5 bash -c 'echo fixture-failure >&2; exit 7'
awk -F '\t' '$1 == "failed.txt" && $4 == 7 { found=1 } END { exit !found }' "$work/commands.tsv"
[[ $failures == 1 ]]
(
  # shellcheck disable=SC2329 # Invoked by sourced collection functions.
  capture() {
    local output=$work/$1
    mkdir -p -- "${output%/*}"
    : >"$output"
    case "$1" in
    incus/projects.csv) printf 'tenant-extra (current)\n' >"$output" ;;
    */containers.csv) printf 'worker-new\n' >"$output" ;;
    */networks.csv) printf 'bridge-extra,YES\nphysical0,NO\n' >"$output" ;;
    esac
  }
  # shellcheck disable=SC2329 # Avoid executing acquisition or compression.
  capture_zstd() { capture "$@"; }
  work=$temporary/discovery
  collect_user
  collect_root
  [[ -f $work/guests/tenant-extra/worker-new/journal.export.zst ]]
  [[ -f $work/incus/projects/tenant-extra/bridge-extra-forwards.yaml ]]
  [[ ! -e $work/incus/projects/tenant-extra/physical0-forwards.yaml ]]
)

printf 'fixture only\n' >"$temporary/collection.txt"
tar --zstd -C "$temporary" -cf "$temporary/collection.tar.zst" collection.txt
export LOG_TEST_ARCHIVE=$temporary/collection.tar.zst LOG_TEST_EVENTS=$temporary/events

record_socket() {
  local option
  for option in "$@"; do
    [[ $option != ControlPath=* ]] || printf '%s\n' "$option" >>"$LOG_TEST_EVENTS"
  done
}
ssh() {
  record_socket "$@"
  if [[ " $* " == *' -O exit '* ]]; then
    printf 'closed\n' >>"$LOG_TEST_EVENTS"
    return 0
  fi
  case "${!#}" in
  *'mktemp -d'*) printf '/srv/operator/log-collection.TEST\n' ;;
  'umask 077; tar '*) tar -tf - >/dev/null ;;
  'bash '*'/collect-logs-remote.sh '*)
    [[ $LOG_TEST_CASE != collect-fail ]] || return 7
    ;;
  *) return 99 ;;
  esac
}
scp() {
  record_socket "$@"
  local destination=${!#}
  case "$LOG_TEST_CASE" in
  transfer-fail)
    printf partial >"$destination"
    return 7
    ;;
  corrupt) printf broken >"$destination" ;;
  *) cp -- "$LOG_TEST_ARCHIVE" "$destination" ;;
  esac
}
export -f record_socket ssh scp

# One normal case and the failures that must not be reported as complete.
for scenario in success collect-fail transfer-fail corrupt; do
  export LOG_TEST_CASE=$scenario
  : >"$LOG_TEST_EVENTS"
  status=0
  bash "$script_dir/collect-logs.sh" operator@another-host "$temporary/$scenario" \
    >"$temporary/$scenario.txt" 2>&1 || status=$?
  case "$scenario" in
  success) [[ $status == 0 ]] ;;
  collect-fail | transfer-fail) [[ $status == 7 ]] ;;
  corrupt) [[ $status == 1 ]] ;;
  esac
  [[ $(tail -n 1 "$LOG_TEST_EVENTS") == closed ]]
  [[ $(grep '^ControlPath=' "$LOG_TEST_EVENTS" | sort -u | wc -l) == 1 ]]
  if [[ $scenario == success || $scenario == collect-fail ]]; then
    [[ $(find "$temporary/$scenario" -name collection.tar.zst | wc -l) == 1 ]]
    [[ $(find "$temporary/$scenario" -name receipt.txt | wc -l) == 1 ]]
  else
    [[ $(find "$temporary/$scenario" -name '*.partial' | wc -l) == 1 ]]
    [[ $(find "$temporary/$scenario" -name receipt.txt | wc -l) == 0 ]]
  fi
done
printf 'log collection fixture tests passed\n'
