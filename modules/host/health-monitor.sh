#!/usr/bin/env bash
set -euo pipefail

project=user-1000
alerts=()

container_states=$(incus list --project "$project" --format csv --columns ns)
while IFS=, read -r name status; do
  [[ -n $name ]] || continue
  [[ $status == RUNNING ]] || alerts+=("container $name: $status")
done <<<"$container_states"

kernel_events=$(journalctl --dmesg --boot=all --since "17 minutes ago" --no-pager --quiet --output=short-iso)
kernel_alerts=$(
  grep -Ei \
    '(oom-kill:|(Out of memory|Memory cgroup out of memory): Killed process|Out of memory: .*panic_on_oom)|BTRFS(:| ) (error|critical) \(device |BTRFS.*(csum|checksum|corrupt)|(I/O|critical (medium|target)|timeout|protection|not ready) error, dev |Buffer I/O error on dev|INFO: task .* blocked for more than .* seconds|watchdog: BUG: soft lockup|Watchdog detected hard LOCKUP|rcu: INFO: rcu_.*(detected stalls|self-detected stall)|Kernel panic - not syncing' \
    <<<"$kernel_events" || true
)
if [[ -n $kernel_alerts ]]; then
  alerts+=("kernel events from the last 17 minutes:" "$kernel_alerts")
fi

failed_units=$(systemctl --failed --no-legend --plain --no-pager)
if [[ -n $failed_units ]]; then
  alerts+=("failed systemd units:" "$failed_units")
fi

((${#alerts[@]})) || exit 0

topic=$(SOPS_AGE_KEY_FILE=/var/lib/sops-nix/key.txt sops decrypt \
  --extract '["ntfy_topic"]' "$HOST_MONITOR_SECRET_FILE")
printf -v message '%s\n' "${alerts[@]}"

curl --silent --show-error --fail --output /dev/null --max-time 15 \
  --header "Title: Host health warning: $(hostname --short)" \
  --header "Priority: 5" \
  --header "Tags: warning" \
  --data-binary "$message" \
  "https://ntfy.sh/$topic"
