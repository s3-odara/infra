#!/usr/bin/env bash
set -euo pipefail

threshold=80
btrfs_unallocated_min_bytes=$((2 * 1024 * 1024 * 1024))
btrfs_metadata_warn_unallocated_bytes=$((4 * 1024 * 1024 * 1024))
btrfs_metadata_threshold=90
project=user-1000
alerts=()

check_usage() {
  local name=$1 used=$2 total=$3 limit=${4:-$threshold}

  ((total > 0 && used * 100 >= total * limit)) || return 0
  alerts+=("$name: $((used * 100 / total))% ($(numfmt --to=iec-i --suffix=B "$used") / $(numfmt --to=iec-i --suffix=B "$total"))")
}

read -r used total < <(df -B1 --output=used,size / | awk 'NR == 2 { print $1, $2 }')
check_usage "host root" "$used" "$total"

btrfs_usage=$(btrfs-root-usage)
read -r btrfs_unallocated btrfs_device_size metadata_used metadata_size <<<"$btrfs_usage"
if ((btrfs_unallocated < btrfs_unallocated_min_bytes)); then
  alerts+=("host btrfs unallocated: $(numfmt --to=iec-i --suffix=B "$btrfs_unallocated") / $(numfmt --to=iec-i --suffix=B "$btrfs_device_size") (metadata: $((metadata_used * 100 / metadata_size))%)")
elif ((btrfs_unallocated < btrfs_metadata_warn_unallocated_bytes)); then
  check_usage "host btrfs metadata" "$metadata_used" "$metadata_size" "$btrfs_metadata_threshold"
fi

while IFS= read -r container; do
  read -r used total < <(
    incus query "/1.0/storage-pools/default/volumes/container/$container/state?project=$project" |
      jq -r '.usage | "\(.used) \(.total)"'
  )
  check_usage "container $container" "$used" "$total"
done < <(incus list --project "$project" --format csv --columns n)

((${#alerts[@]})) || exit 0

topic=$(SOPS_AGE_KEY_FILE=/var/lib/sops-nix/key.txt sops decrypt \
  --extract '["ntfy_topic"]' "$STORAGE_MONITOR_SECRET_FILE")
printf -v message '%s\n' "${alerts[@]}"

curl --silent --show-error --fail --output /dev/null --max-time 15 \
  --header "Title: Storage usage warning: $(hostname --short)" \
  --header "Priority: 5" \
  --header "Tags: warning" \
  --data-binary "$message" \
  "https://ntfy.sh/$topic"
