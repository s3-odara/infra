#!/usr/bin/env bash
# Run on the target NixOS + Incus host. Only the root phase requires doas.
set -euo pipefail

usage() {
  printf 'Usage: bash collect-logs-remote.sh [NEW_RESULT_DIRECTORY]\n' >&2
  printf 'Internal phases: <--user|--root> > phase.tar\n' >&2
}
fail() {
  printf 'collect-logs-remote: %s\n' "$*" >&2
  exit 1
}

# Archive the selected paths, including rotations, without following symlinks.
# shellcheck disable=SC2016 # Executed later inside the inspected node.
raw_logs='unset TAR_OPTIONS
paths=()
for path; do
  if [[ -e $path || -L $path ]]; then paths+=("${path#/}"); fi
done
((${#paths[@]})) || { echo "No log directories exist" >&2; exit 3; }
exec tar --numeric-owner --acls --xattrs -C / -cf - -- "${paths[@]}"'

# Resolve link metadata only; never read the target contents.
# shellcheck disable=SC2016 # Executed later inside the inspected node.
log_symlinks='set -o pipefail
paths=() roots=()
for path; do
  [[ -e $path || -L $path ]] || continue
  paths+=("$path")
  # A selected root that is itself a symlink is not traversed by tar.
  if [[ ! -L $path ]] && IFS= read -r -d "" resolved < <(readlink -ez -- "$path"); then
    roots+=("$resolved")
  fi
done
((${#paths[@]})) || { echo "No log directories exist" >&2; exit 3; }
printf "status\tlink\ttarget\tresolved_target\n"
find -P "${paths[@]}" -type l -print0 |
  while IFS= read -r -d "" link; do
    status=unresolved
    target="" resolved=""
    IFS= read -r -d "" target < <(readlink -z -- "$link") || true
    if IFS= read -r -d "" resolved < <(readlink -ez -- "$link"); then
      status=outside
      for root in "${roots[@]}"; do
        if [[ $resolved == "$root" || $resolved == "$root/"* ]]; then
          status=inside
          break
        fi
      done
    fi
    [[ $status != inside ]] || continue
    printf "%s\t%q\t%q\t%q\n" "$status" "$link" "$target" "$resolved"
  done'

# shellcheck disable=SC2016 # Executed later inside the inspected node.
persistence_metadata='paths=()
for path in /etc/systemd/system /run/systemd/system /etc/cron.d /etc/crontab /var/spool/cron /etc/profile /etc/bashrc /etc/ld.so.preload /etc/ssh/authorized_keys.d /tmp /var/tmp /dev/shm /run/secrets /var/lib/sops-nix /etc/nixos-secrets; do
  if [[ -e $path || -L $path ]]; then paths+=("$path"); fi
done
accounts=$(getent passwd) || exit 1
while IFS=: read -r _ _ _ _ _ home _; do
  [[ $home == /* && $home != / ]] || continue
  for suffix in .ssh .config/systemd .bashrc .profile; do
    path=$home/$suffix
    if [[ -e $path || -L $path ]]; then paths+=("$path"); fi
  done
done <<<"$accounts"
((${#paths[@]})) || exit 0
exec find "${paths[@]}" -xdev -maxdepth 5 -printf "%T+ %C+ %U:%G %m %y %p -> %l\n"'

# shellcheck disable=SC2016 # Executed later inside the inspected node.
executable_links='for path in /proc/[0-9]*/exe; do
  target=$(readlink -- "$path" 2>/dev/null) || continue
  printf "%s -> %s\n" "$path" "$target"
done'

# Each command has bounded time/space and records its output and exit status.
capture() {
  local name=$1 seconds=$2
  shift 2
  local started rc=0 free_kib used_kib limit_kib
  started=$(date -u +%FT%TZ)
  mkdir -p -- "$work/$(dirname -- "$name")"
  free_kib=$(df -Pk "$work" | awk 'END { print $4 }')
  used_kib=$(du -sk "$work" | awk '{ print $1 }')
  # Reserve 512 MiB and space to package another copy of the collected data.
  limit_kib=$(((free_kib - used_kib - 524288) / 4))
  ((limit_kib <= 524288)) || limit_kib=524288
  if ((limit_kib < 1024)); then
    printf 'Skipped: insufficient staging space\n' >"$work/$name.stderr"
    : >"$work/$name"
    rc=125
  else
    printf 'Collecting %s\n' "$name" >&2
    if (
      set +o posix # Keep Bash ulimit -f units in KiB, not POSIX 512-byte blocks.
      ulimit -f "$limit_kib"
      exec timeout --kill-after=5s "${seconds}s" "$@"
    ) >"$work/$name" 2>"$work/$name.stderr" </dev/null; then
      rc=0
    else
      rc=$?
    fi
  fi
  {
    printf '%s\t%s\t%s\t%s\t%s\t' "$name" "$started" "$(date -u +%FT%TZ)" "$rc" "$limit_kib"
    printf '%q ' "$@"
    printf '\n'
  } >>"$work/commands.tsv"
  if ((rc != 0)); then
    failures=$((failures + 1))
    printf 'Incomplete: %s (exit %s)\n' "$name" "$rc" >&2
  fi
}
capture_zstd() {
  local name=$1 seconds=$2
  shift 2
  capture "$name" "$seconds" bash -o pipefail -c '"$@" | zstd --quiet --threads=1 -1 --stdout' bash "$@"
}
valid_name() {
  [[ $1 =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]] && return 0
  printf 'Skipped unsafe Incus resource name: %q\n' "$1" >>"$work/discovery-errors.txt"
  failures=$((failures + 1))
  return 1
}
volatile() {
  local label=$1
  shift
  capture "$label/identity.txt" 10 "$@" bash -c 'date -u --iso-8601=seconds; hostname; id; uname -a; uptime'
  capture "$label/processes.txt" 20 "$@" ps -eo pid,ppid,user,lstart,comm --forest
  capture "$label/listeners.txt" 20 "$@" ss -lntup
  capture "$label/connections.txt" 20 "$@" ss -tunap
  capture "$label/executables.txt" 20 "$@" bash -c "$executable_links"
}
inventory() {
  local label=$1
  shift
  capture "$label/users.txt" 10 "$@" getent passwd
  capture "$label/groups.txt" 10 "$@" getent group
  capture "$label/services.txt" 20 "$@" systemctl list-units --type=service --all --no-pager
  capture "$label/unit-files.txt" 20 "$@" systemctl list-unit-files --no-pager
  capture "$label/timers.txt" 20 "$@" systemctl list-timers --all --no-pager
  capture "$label/unit-overrides.txt" 20 "$@" systemd-delta --no-pager
  capture "$label/system-paths.txt" 10 "$@" readlink -f /run/current-system /run/booted-system /nix/var/nix/profiles/system
  capture "$label/nixos-version.txt" 10 "$@" nixos-version --json
  capture "$label/generations.txt" 20 "$@" nix-env -p /nix/var/nix/profiles/system --list-generations
}
journals() {
  local label=$1
  local log_paths=(/var/log /run/log/journal)
  shift
  capture_zstd "$label/raw-logs.tar.zst" 180 "$@" bash -c "$raw_logs" bash "${log_paths[@]}"
  capture_zstd "$label/journal.export.zst" 120 "$@" journalctl --boot=all --no-pager -o export
  capture "$label/boots.txt" 20 "$@" journalctl --list-boots --no-pager
  capture "$label/journal-usage.txt" 10 "$@" journalctl --disk-usage
  capture "$label/log-symlinks.tsv" 30 "$@" bash -c "$log_symlinks" bash "${log_paths[@]}"
}

collect_user() {
  local project guest label
  capture host/identity.txt 10 bash -c 'date -u --iso-8601=seconds; hostname; id; uname -a; uptime'
  capture host/sessions.txt 10 loginctl list-sessions --no-pager
  capture host/who.txt 10 who
  capture host/mounts.txt 10 findmnt
  capture host/disk-space.txt 10 df -h
  capture host/addresses.txt 10 ip -details address
  capture host/routes.txt 10 ip route show table all
  inventory host
  capture incus/projects.csv 20 incus project list --format csv --columns n
  while IFS= read -r project; do
    project=${project% (current)}
    [[ -n $project ]] || continue
    valid_name "$project" || continue
    capture "incus/projects/$project/instances.json" 30 incus list --project "$project" --format json
    capture "incus/projects/$project/containers.csv" 30 incus list type=container --project "$project" --format csv --columns n
    while IFS= read -r guest; do
      [[ -n $guest ]] || continue
      valid_name "$guest" || continue
      label=guests/$project/$guest
      # The caller uses its existing Incus rights; guest commands run as guest root.
      volatile "$label" incus exec -T --project "$project" "$guest" --
      journals "$label" incus exec -T --project "$project" "$guest" --
      inventory "$label" incus exec -T --project "$project" "$guest" --
      capture "$label/persistence-metadata.txt" 30 incus exec -T --project "$project" "$guest" -- bash -c "$persistence_metadata"
    done <"$work/incus/projects/$project/containers.csv"
  done <"$work/incus/projects.csv"
}
collect_root() {
  local project network managed
  volatile host
  journals host
  capture_zstd host/remote-journal.export.zst 120 journalctl --directory=/var/log/journal/remote --boot=all --no-pager -o export
  capture host/kernel.txt 30 journalctl --utc --boot=all --no-pager -k
  capture host/sshd-effective.txt 10 sshd -T
  # shellcheck disable=SC2016 # Only public key fingerprints are read.
  capture host/authorized-key-fingerprints.txt 10 bash -ec '
    for key in /etc/ssh/authorized_keys.d/*; do
      if [[ -f $key ]]; then printf "%s\n" "$key"; ssh-keygen -lf "$key"; fi
    done
    accounts=$(getent passwd)
    while IFS=: read -r _ _ _ _ _ home _; do
      [[ $home == /* && $home != / ]] || continue
      key=$home/.ssh/authorized_keys
      if [[ -f $key ]]; then printf "%s\n" "$key"; ssh-keygen -lf "$key"; fi
    done <<<"$accounts"'
  capture host/nftables.txt 30 nft -a list ruleset
  capture host/persistence-metadata.txt 30 bash -c "$persistence_metadata"
  capture incus/all-instances.json 30 incus list --all-projects --format json
  capture incus/server.yaml 20 incus config show
  capture incus/trust.txt 20 incus config trust list
  capture incus/storage.yaml 20 incus storage list --format yaml
  capture incus/projects.csv 20 incus project list --format csv --columns n
  while IFS= read -r project; do
    project=${project% (current)}
    [[ -n $project ]] || continue
    valid_name "$project" || continue
    capture "incus/projects/$project/project.yaml" 20 incus project show "$project"
    capture "incus/projects/$project/profiles.yaml" 20 incus profile list --project "$project" --format yaml
    capture "incus/projects/$project/acls.yaml" 20 incus network acl list --project "$project" --format yaml
    capture "incus/projects/$project/networks.yaml" 20 incus network list --project "$project" --format yaml
    capture "incus/projects/$project/networks.csv" 20 incus network list --project "$project" --format csv --columns nm
    while IFS=, read -r network managed; do
      [[ $managed == YES || $managed == true ]] || continue
      valid_name "$network" || continue
      capture "incus/projects/$project/$network-forwards.yaml" 20 incus network forward list "$network" --project "$project" --format yaml
    done <"$work/incus/projects/$project/networks.csv"
  done <"$work/incus/projects.csv"
}

collect_phase() {
  (($# == 1)) || {
    usage
    return 2
  }
  local phase=${1#--}
  case "$1" in
  --root) ((EUID == 0)) || fail 'Run the root phase with doas.' ;;
  --user) ((EUID != 0)) || fail 'Run the user phase without doas.' ;;
  *)
    usage
    return 2
    ;;
  esac
  [[ ! -t 1 ]] || fail 'Redirect the phase archive to a file.'
  export PATH=/run/current-system/sw/bin:/run/wrappers/bin:/usr/bin:/bin
  export LC_ALL=C TZ=UTC SYSTEMD_COLORS=0 SYSTEMD_PAGER=cat
  unset POSIXLY_CORRECT TAR_OPTIONS
  umask 077
  for tool in timeout tar zstd find readlink df du awk date mktemp cp nixos-version incus; do
    command -v "$tool" >/dev/null || fail "Required tool is missing: $tool (nothing will be installed)"
  done
  work=$(mktemp -d "/var/tmp/log-collection-$phase.XXXXXXXXXX")
  trap 'rm -rf -- "$work"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
  failures=0
  printf 'name\tstarted_utc\tended_utc\texit_code\tfile_limit_kib\tcommand\n' >"$work/commands.tsv"
  printf 'phase=%s\nuid=%s\nstarted_utc=%s\n' "$phase" "$EUID" "$(date -u +%FT%TZ)" >"$work/collection.txt"
  cp -- "${BASH_SOURCE[0]}" "$work/collector.sh"
  printf '%s\n' \
    'Selected log directories and journals are requested, subject to time/space limits.' \
    'Raw log archives do not follow symlinks; see log-symlinks.tsv for outside/unresolved links.' \
    'Read collection.txt, commands.tsv and .stderr files for incomplete acquisition.' \
    'Archive creation and transfer do not establish completeness or evidence authenticity.' \
    'Logs and configuration may contain personal data or credentials.' \
    'Do not extract as root, overwrite existing files, or execute collected scripts.' >"$work/READ-ME.txt"
  "collect_$phase"
  printf 'finished_utc=%s\nincomplete_commands=%s\n' "$(date -u +%FT%TZ)" "$failures" >>"$work/collection.txt"
  # Large log outputs are already compressed; keep the phase handoff as plain tar.
  tar -C "$work" -cf - .
}

# Keep the parent unprivileged; only the root phase needs doas.
collect_all() {
  (($# <= 1)) || {
    usage
    return 2
  }
  ((EUID != 0)) || fail 'Run without doas; only the root phase uses it.'
  command -v zstd >/dev/null || fail 'zstd is required (nothing will be installed).'
  local collector result phase status failed=0
  local files=(collection.txt) command_line
  unset TAR_OPTIONS
  umask 077
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
  collector=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/collect-logs-remote.sh
  if (($# == 1)); then
    result=$1
    [[ $result == /* ]] || fail 'Result directory must be absolute.'
    mkdir -- "$result"
  else
    result=$(mktemp -d "$HOME/log-collection.XXXXXXXXXX")
  fi
  printf 'Result directory: %s\n' "$result"
  printf 'started_utc=%s\n' "$(date -u +%FT%TZ)" >"$result/collection.txt"
  for phase in user root; do
    if [[ $phase == root ]]; then
      printf 'Authorize doas for host-privileged collection only.\n' >&2
      command_line=(doas bash "$collector" --root)
    else
      command_line=(bash "$collector" --user)
    fi
    status=0
    if "${command_line[@]}" >"$result/$phase.tar.partial"; then
      mv -- "$result/$phase.tar.partial" "$result/$phase.tar"
      files+=("$phase.tar")
    else
      status=$?
      files+=("$phase.tar.partial")
    fi
    printf '%s_phase_exit=%s\n' "$phase" "$status" >>"$result/collection.txt"
    if ((status != 0)); then
      failed=$((failed + 1))
      printf '%s phase failed (exit %s); partial output retained.\n' "$phase" "$status" >&2
    fi
  done
  printf 'finished_utc=%s\nfailed_phases=%s\n' "$(date -u +%FT%TZ)" "$failed" >>"$result/collection.txt"
  tar -C "$result" -cf - "${files[@]}" | zstd --quiet --threads=1 -1 --stdout >"$result/collection.tar.zst.partial"
  mv -- "$result/collection.tar.zst.partial" "$result/collection.tar.zst"
  printf 'Archive ready: %s/collection.tar.zst\n' "$result"
  printf 'Inspect phase metadata for incomplete acquisition.\n'
  return "$((failed != 0))"
}
main() {
  case ${1:-} in
  --help) usage ;;
  --user | --root) collect_phase "$@" ;;
  *) collect_all "$@" ;;
  esac
}
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
