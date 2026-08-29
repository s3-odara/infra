#!/usr/bin/env bash
set -euo pipefail

threshold=80
project=user-1000
alerts=()

check_usage() {
  local name=$1 used=$2 total=$3

  ((used * 100 >= total * threshold)) || return 0
  alerts+=("$name: $((used * 100 / total))% ($(numfmt --to=iec-i --suffix=B "$used") / $(numfmt --to=iec-i --suffix=B "$total"))")
}

read -r used total < <(df -B1 --output=used,size / | awk 'NR == 2 { print $1, $2 }')
check_usage "host root" "$used" "$total"

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
